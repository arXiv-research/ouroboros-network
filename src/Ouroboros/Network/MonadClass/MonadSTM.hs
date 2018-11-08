{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE TypeFamilyDependencies #-}
module Ouroboros.Network.MonadClass.MonadSTM
  ( MonadSTM (..) ) where

import qualified Control.Concurrent.STM.TVar as STM
import qualified Control.Monad.STM as STM

import           Ouroboros.Network.MonadClass.MonadFork

class (MonadFork m, Monad (Tr m)) => MonadSTM m where
  type Tr   m = (n :: * -> *) | n -> m -- ^ STM transactions
  type TVar m :: * -> *

  atomically   :: Tr m a -> m a
  newTVar      :: a -> Tr m (TVar m a)
  readTVar     :: TVar m a -> Tr m a
  writeTVar    :: TVar m a -> a -> Tr m ()
  modifyTVar   :: TVar m a -> (a -> a) -> Tr m ()
  modifyTVar  v f = readTVar v >>= writeTVar v . f
  modifyTVar'  :: TVar m a -> (a -> a) -> Tr m ()
  modifyTVar' v f = do
    a <- readTVar v
    writeTVar v $! f a
  retry        :: Tr m a
--orElse       :: Tr m a -> Tr m a -> Tr m a --TODO

  check        :: Bool -> Tr m ()
  check True = return ()
  check _    = retry

instance MonadSTM IO where
  type Tr   IO = STM.STM
  type TVar IO = STM.TVar

  atomically  = STM.atomically
  newTVar     = STM.newTVar
  readTVar    = STM.readTVar
  writeTVar   = STM.writeTVar
  retry       = STM.retry
  modifyTVar  = STM.modifyTVar
  modifyTVar' = STM.modifyTVar'
  check       = STM.check
