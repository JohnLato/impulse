{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

{-# OPTIONS_GHC -Wall -fno-prof-auto #-}
{- Use this internally because the transformers RWST leaks in the W part -}
module Reactive.Impulse.Internal.RWST (
  RWST(..)
, runRWST
, execRWST
, evalRWST
, mapRWST
, withRWST

, reader
, ask
, local
, asks

, writer
, tell
, listen
, listens
, pass
, censor

, state
, get
, put
, modify
, gets

, module Data.Monoid
, module Control.Monad.Trans
) where

import Control.Applicative
import Control.Monad
import qualified Control.Monad.Reader.Class as RWS
import qualified Control.Monad.Writer.Class as RWS
import qualified Control.Monad.State.Class as RWS
import Control.Monad.Trans
import Control.Monad.Fix

import Data.Monoid

newtype RWST r w s m a = RWST { runRWST' :: w -> r -> s -> m (a, s, w) }

runRWST :: Monoid w => RWST r w s m a -> r -> s -> m (a, s, w)
runRWST rws = runRWST' rws mempty

evalRWST :: (Monad m, Monoid w)
         => RWST r w s m a
         -> r
         -> s
         -> m (a, w)
evalRWST m r s = do
    (a, _, w) <- runRWST m r s
    return (a, w)

execRWST :: (Monad m, Monoid w)
         => RWST r w s m a
         -> r
         -> s
         -> m (s, w)
execRWST m r s = do
    (_, s', w) <- runRWST m r s
    return (s', w)

mapRWST :: (m (a, s, w) -> n (b, s, w)) -> RWST r w s m a -> RWST r w s n b
mapRWST f m = RWST $ \w r s -> f (runRWST' m w r s)

withRWST :: (r' -> s -> (r, s)) -> RWST r w s m a -> RWST r' w s m a
withRWST f m = RWST $ \w r s -> uncurry (runRWST' m w) (f r s)

instance (Functor m) => Functor (RWST r w s m) where
    fmap f m = RWST $ \w0 r s ->
        fmap (\ (a, s', w) -> (f a, s', w)) $ runRWST' m w0 r s

instance (Functor m, Monad m) => Applicative (RWST r w s m) where
    pure = return
    (<*>) = ap

instance (Functor m, MonadPlus m) => Alternative (RWST r w s m) where
    empty = mzero
    (<|>) = mplus

instance (Monad m) => Monad (RWST r w s m) where
    {-# INLINE return #-}
    return a = RWST $ \w _ s -> return (a, s, w)
    {-# INLINE (>>=) #-}
    m >>= k  = RWST $ \w0 r s -> do
        (!a, !s', !w)  <- runRWST' m w0 r s
        (!b, !s'',!w') <- runRWST' (k a) w r s'
        return (b, s'', w')
    fail msg = RWST $ \_ _ -> fail msg

instance (MonadPlus m) => MonadPlus (RWST r w s m) where
    mzero       = RWST $ \_ _ _ -> mzero
    m `mplus` n = RWST $ \w r s -> runRWST' m w r s `mplus` runRWST' n w r s

instance (MonadFix m) => MonadFix (RWST r w s m) where
    mfix f = RWST $ \w r s -> mfix $ \ (a, _, _) -> runRWST' (f a) w r s

instance MonadTrans (RWST r w s) where
    lift m = RWST $ \w _ s -> do
        a <- m
        return (a, s, w)

instance (MonadIO m) => MonadIO (RWST r w s m) where
    liftIO = lift . liftIO

-- ---------------------------------------------------------------------------
-- Reader operations

reader :: (Monad m) => (r -> a) -> RWST r w s m a
reader = asks

ask :: (Monad m) => RWST r w s m r
ask = RWST $ \w r s -> return (r, s, w)

local :: (Monad m) => (r -> r) -> RWST r w s m a -> RWST r w s m a
local f m = RWST $ \w r s -> runRWST' m w (f r) s

asks :: (Monad m) => (r -> a) -> RWST r w s m a
asks f = RWST $ \w r s -> return (f r, s, w)

-- ---------------------------------------------------------------------------
-- Writer operations

writer :: (Monad m, Monoid w) => (a, w) -> RWST r w s m a
writer (a, w) = RWST $ \w' _ s -> let !w'2 = w' `mappend` w in return (a, s, w'2)

tell :: (Monoid w, Monad m) => w -> RWST r w s m ()
tell w = RWST $ \w' _ s -> let !w'2 = w' `mappend` w in return ((),s,w'2)

listen :: (Monad m) => RWST r w s m a -> RWST r w s m (a, w)
listen m = RWST $ \w r s -> do
    (a, s', w') <- runRWST' m w r s
    return ((a, w'), s', w')

listens :: (Monad m) => (w -> b) -> RWST r w s m a -> RWST r w s m (a, b)
listens f m = RWST $ \w r s -> do
    (a, s', w') <- runRWST' m w r s
    return ((a, f w'), s', w')

pass :: (Monad m) => RWST r w s m (a, w -> w) -> RWST r w s m a
pass m = RWST $ \w r s -> do
    ((a, f), s', w') <- runRWST' m w r s
    return (a, s', f w')

censor :: (Monad m) => (w -> w) -> RWST r w s m a -> RWST r w s m a
censor f m = RWST $ \w r s -> do
    (a, s', w') <- runRWST' m w r s
    return (a, s', f w')

-- ---------------------------------------------------------------------------
-- State operations

state :: (Monad m) => (s -> (a,s)) -> RWST r w s m a
state f = RWST $ \w _ s -> let (a,s') = f s  in  return (a, s', w)

get :: (Monad m) => RWST r w s m s
get = RWST $ \w _ s -> return (s, s, w)

put :: (Monad m) => s -> RWST r w s m ()
put s = RWST $ \w _ _ -> return ((), s, w)

modify :: (Monad m) => (s -> s) -> RWST r w s m ()
modify f = RWST $ \w _ s -> return ((), f s, w)
 
gets :: (Monad m) => (s -> a) -> RWST r w s m a
gets f = RWST $ \w _ s -> return (f s, s, w)

-- ---------------------------------------------------------------------------
-- MTL stuff

instance (Monad m) => RWS.MonadReader r (RWST r w s m) where
    ask = ask
    local = local
    reader = reader
instance (Monad m) => RWS.MonadState s (RWST r w s m) where
    get = get
    put = put
    state = state
instance (Monoid w, Monad m) => RWS.MonadWriter w (RWST r w s m) where
    writer = writer
    tell = tell
    listen = listen
    pass = pass
