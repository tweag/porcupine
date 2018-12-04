{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FunctionalDependencies #-}

module Control.Monad.ReaderSoup
  ( module Control.Monad.Trans.Reader
  , MonadReader(..)
  , Identity(..)
  , ReaderSoup_(..)
  , ReaderSoup
  , CookedReaderSoup
  , ContextFromName
  , IsInSoup
  , Chopsticks(..)
  , SoupContext(..)
  , consumeSoup
  , ArgsForSoupConsumption
  , cookReaderSoup
  , pickTopping
  , eatTopping
  , finishBroth
  , askSoup
  , filtering
  , picking
  , withChopsticks
  , rioToChopsticks
  , inPrefMonad
  ) where

import Control.Lens (over, Identity(..))
import Control.Monad.Reader.Class
import Control.Monad.IO.Unlift
import Control.Monad.Trans.Reader hiding (ask, local, reader)
import Data.Proxy
import Data.Vinyl hiding (record)
import Data.Vinyl.TypeLevel
import GHC.TypeLits
import GHC.OverloadedLabels


-- | Represents a set of Reader-like monads as a one-layer Reader that can grow
-- and host more Readers, in a way that's more generic than creating you own
-- application stack of Reader and implementing a host of MonadXXX classes,
-- because each of these MonadXXX classes can be implemented once and for all
-- for ReaderSoup.
newtype ReaderSoup_ (record::((Symbol, *) -> *) -> [(Symbol, *)] -> *) ctxs a = ReaderSoup
  { unReaderSoup ::
      ReaderT (record ElField ctxs) IO a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadUnliftIO)

-- | The type of 'ReaderSoup_' your application will eat
type ReaderSoup = ReaderSoup_ ARec

-- | A 'ReaderSoup' ready to be eaten
type CookedReaderSoup = ReaderSoup_ Rec


-- * Eating (running) a 'ReaderSoup'

-- | Turns a 'ReaderSoup' into something than is ready to be eaten
cookReaderSoup :: (NatToInt (RLength ctxs))
               => ReaderSoup ctxs a
               -> CookedReaderSoup ctxs a
cookReaderSoup (ReaderSoup (ReaderT act)) =
  ReaderSoup $ ReaderT $ act . toARec

-- | Extracts a ReaderT of the first context so it can be eaten
pickTopping :: (KnownSymbol l)
            => CookedReaderSoup ( (l:::c) : ctxs ) a
            -> ReaderT c (CookedReaderSoup ctxs) a
pickTopping (ReaderSoup (ReaderT actInSoup)) =
  ReaderT $ \ctx1 -> ReaderSoup $
    ReaderT $ \ctxs -> actInSoup $ Field ctx1 :& ctxs

-- | Consumes the first context in the record
eatTopping :: (KnownSymbol l)
           => CookedReaderSoup ( (l:::c) : ctxs ) a
           -> c
           -> CookedReaderSoup ctxs a
eatTopping crs = runReaderT (pickTopping crs)

-- | Once all contexts have been eaten, leaves only the base monad
finishBroth :: CookedReaderSoup '[] a -> IO a
finishBroth (ReaderSoup (ReaderT act)) = act RNil

-- | Associates the type-level label to the reader context
type family ContextFromName (l::Symbol) :: *

type IsInSoup ctxs l =
  ( HasField ARec l ctxs ctxs (ContextFromName l) (ContextFromName l) )
  -- , RecElemFCtx ARec ElField )


-- * Working in a 'ReaderSoup'

askSoup :: (IsInSoup ctxs l)
        => Label l -> ReaderSoup ctxs (ContextFromName l)
askSoup l = ReaderSoup $ rvalf l <$> ask

-- | Permits to select only a part of the whole contexts, to locally decide
-- which part of the ReaderSoup will be exposed, and remove ambiguity.
filtering :: (RecSubset ARec ctxs' ctxs (RImage ctxs' ctxs))
          => ReaderSoup ctxs' a
          -> ReaderSoup ctxs a
filtering (ReaderSoup (ReaderT act)) =
  ReaderSoup $ ReaderT $ act . rcast
  -- NOTE: this isn't as fast as 'picking' as it recreates an array, rather than
  -- just a view to the original


-- * Compatibility with existing ReaderT-like monads

-- | Select temporarily one context out of the whole soup to create a
-- MonadReader of that context. 'Chopsticks' behaves exactly like a @ReaderT r
-- IO@ (where r is the ContextFromName of @l@) but that keeps track of the whole
-- context array.
newtype Chopsticks ctxs (l::Symbol) a = Chopsticks
  { unChopsticks :: ReaderSoup ctxs a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadUnliftIO)

instance (IsInSoup ctxs l, c ~ ContextFromName l)
      => MonadReader c (Chopsticks ctxs l) where
  ask = Chopsticks $ askSoup $ fromLabel @l
  local f (Chopsticks (ReaderSoup (ReaderT act))) =
    Chopsticks $ ReaderSoup $ ReaderT $
      act . over (rlensf (fromLabel @l)) f

-- | Brings forth one context of the whole soup, giving a MonadReader instance
-- of just this context. This makes it possible that the same context type
-- occurs several times in the broth, because the Label will disambiguate them.
picking :: (IsInSoup ctxs l)
        => Label l
        -> Chopsticks ctxs l a
        -> ReaderSoup ctxs a
picking _ = unChopsticks

-- | If you have a code that cannot cope with any MonadReader but explicitly
-- wants a ReaderT
rioToChopsticks :: forall l ctxs a. (IsInSoup ctxs l)
                => ReaderT (ContextFromName l) IO a -> Chopsticks ctxs l a
rioToChopsticks (ReaderT act) = Chopsticks $ ReaderSoup $ ReaderT $
  act . rvalf (fromLabel @l)


-- | A class for the contexts that have an associated monad transformer that can
-- be turned into a ReaderT of this context, and the type of monad over which
-- they can run.
class (Monad m) => SoupContext c m where
  -- | The parameters to construct that context
  type CtxConstructorArgs c :: *
  -- | The prefered monad trans to run that type of context
  type CtxPrefMonadT c :: (* -> *) -> * -> *
  -- | Turn this monad trans into an actual ReaderT
  toReaderT :: CtxPrefMonadT c m a -> ReaderT c m a
  -- | Reconstruct this monad trans from an actual ReaderT
  fromReaderT :: ReaderT c m a -> CtxPrefMonadT c m a
  -- | Run the CtxPrefMonadT
  runPrefMonadT :: proxy c -> CtxConstructorArgs c -> CtxPrefMonadT c m a -> m a

-- | Converts an action in some ReaderT-of-IO-like monad to 'Chopsticks', this
-- monad being determined by @c@. This is for code that cannot cope with any
-- MonadReader and want some specific monad.
withChopsticks :: forall l ctxs c a.
                  (IsInSoup ctxs l, SoupContext c IO
                  ,c ~ ContextFromName l, KnownSymbol l)
               => ((forall x. Chopsticks ctxs l x -> CtxPrefMonadT c IO x) -> CtxPrefMonadT c IO a)
               -> Chopsticks ctxs l a
withChopsticks act = Chopsticks $ ReaderSoup $ ReaderT $ \record ->
  let
    lbl = fromLabel @l
    backwards :: forall x. Chopsticks ctxs l x -> CtxPrefMonadT c IO x
    backwards (Chopsticks (ReaderSoup (ReaderT act'))) =
      fromReaderT $ ReaderT $ \v -> act' $ rputf lbl v record
  in runReaderT (toReaderT $ act backwards) $ rvalf lbl record

-- | Like 'picking', but instead of 'Chopsticks' runs some preferential
-- Reader-like monad. That permits to reuse some already existing monad from an
-- existing library (ResourceT, KatipContextT, AWST, etc.).
inPrefMonad :: (IsInSoup ctxs l, SoupContext c IO
               ,c ~ ContextFromName l, KnownSymbol l)
            => Label l
            -> ((forall x. ReaderSoup ctxs x -> CtxPrefMonadT c IO x) -> CtxPrefMonadT c IO a)
            -> ReaderSoup ctxs a
inPrefMonad lbl f = picking lbl $ withChopsticks $
  \convert -> f (convert . Chopsticks)

class ArgsForSoupConsumption args where
  type CtxsFromArgs args :: [(Symbol, *)]
  consumeSoup_ :: Rec ElField args -> CookedReaderSoup (CtxsFromArgs args) a -> IO a

instance ArgsForSoupConsumption '[] where
  type CtxsFromArgs '[] = '[]
  consumeSoup_ _ = finishBroth

instance ( ArgsForSoupConsumption restArgs
         , CtxConstructorArgs (ContextFromName l) ~ args1
         , SoupContext (ContextFromName l) (CookedReaderSoup (CtxsFromArgs restArgs)) )
      => ArgsForSoupConsumption ((l:::args1) : restArgs) where
  type CtxsFromArgs ((l:::args1) : restArgs) =
    (l:::ContextFromName l) : CtxsFromArgs restArgs
  consumeSoup_ (Field args :& restArgs) act =
    consumeSoup_ restArgs $
      runPrefMonadT (Proxy :: Proxy (ContextFromName l))
                    args
                    (fromReaderT (pickTopping act))

-- | From the list of the arguments to initialize the contexts, runs the whole
-- 'ReaderSoup'
consumeSoup :: (ArgsForSoupConsumption args, NatToInt (RLength (CtxsFromArgs args)))
            => Rec ElField args -> ReaderSoup (CtxsFromArgs args) a -> IO a
consumeSoup args = consumeSoup_ args . cookReaderSoup
