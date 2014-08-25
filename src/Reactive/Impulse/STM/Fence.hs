{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ViewPatterns #-}

{-# OPTIONS -Wall #-}
module Reactive.Impulse.STM.Fence (
  TransactionManager,
  Ticket,
  newTransactionManager,
  transactSTM,
  transactExclusive,
  maybeExclusive,
  commitExclusive,
) where

import Control.Concurrent.STM
import Control.Applicative
import Data.Word

data TransactionManager = GK
    { gFence :: TMVar Ticket
    , gCommiting :: TVar Ticket
    }

newtype Ticket = Ticket {unTicket :: Word64} deriving (Eq, Ord)

newTransactionManager :: IO TransactionManager
newTransactionManager = GK <$> newTMVarIO (Ticket 0) <*> newTVarIO (Ticket 0)

-- | Run an STM transaction guarded by the 'TransactionManager'.
transactSTM :: TransactionManager -> STM a -> IO a
transactSTM tm akt = atomically $ do
    !_lastFence <- readTMVar $ gFence tm
    akt

-- | Begin an exclusive transaction.  After this function returns, no
-- further transactions may begin until this transaction commits
-- (see 'commitExclusive').
transactExclusive :: TransactionManager -> STM a -> IO (a, Ticket)
transactExclusive tm akt = atomically $ do
    -- slightly re-ordered from maybeExclusive; since we know we'll need to
    -- take the TMVar we may as well do so sooner (which will likely reduce
    -- conflicts with other exclusive transactions
    lastFence <- takeTMVar $ gFence tm
    a <- akt
    let newFence = Ticket $ unTicket lastFence+1
    writeTVar (gCommiting tm) newFence
    return $ (a, newFence)

-- | Commit a transaction.  If the predicate is 'True', an exclusive
-- transaction will be started.
maybeExclusive :: TransactionManager -> (a -> Bool) -> STM a -> IO (a, Maybe Ticket)
maybeExclusive tm p akt = atomically $ do
    lastFence <- takeTMVar $ gFence tm
    a <- akt
    if p a
      then do
          let !newFence = Ticket $ unTicket lastFence+1
          writeTVar (gCommiting tm) newFence
          return $ (a, Just newFence)
      else do
          putTMVar (gFence tm) lastFence
          return (a,Nothing)

-- | Commit an exclusive transaction.  After this commits
-- other transactions may continue.
commitExclusive :: TransactionManager -> Ticket -> IO ()
commitExclusive tm ticket = atomically $ do
    toCommit <- readTVar (gCommiting tm)
    check $ toCommit == ticket
    putTMVar (gFence tm) ticket
