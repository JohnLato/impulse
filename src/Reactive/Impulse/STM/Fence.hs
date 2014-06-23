{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ViewPatterns #-}

{-# OPTIONS -Wall #-}
module Reactive.Impulse.STM.Fence (
  Gatekeeper,
  Ticket,
  newGatekeeper,
  fencedSTM,
  maybeExclusive,
  commitExclusive,
) where

import Control.Concurrent.STM
import Control.Applicative
import Data.Word

data Gatekeeper = GK
    { gFence :: TMVar Ticket
    , gCommiting :: TVar Ticket
    }

newtype Ticket = Ticket {unTicket :: Word} deriving (Eq, Ord, Num)

newGatekeeper :: IO Gatekeeper
newGatekeeper = GK <$> newTMVarIO 0 <$> newTVarIO 0

getLastFence :: GateKeeper -> STM Ticket
getLastFence gk = readTMVar (gFence gk)

checkLastFence :: GateKeeper -> Ticket -> STM Bool
checkLastFence ticket gk = ((== Just ticket) <$> tryReadTMVar (gFence gk))

fencedSTM :: Gatekeeper -> STM a -> IO a
fencedSTM gk akt = atomically $ do
    lastFence  <- getLastFence gk
    always $ checkLastFence gk ticket
    akt

maybeExclusive :: Gatekeeper -> STM a -> (a -> Bool) -> IO (a, Maybe Ticket)
maybeExclusive gk akt p = atomically $ do
    lastFence <- getLastFence gk
    a <- akt
    if p a
      then do
          curFence <- takeTMVar (gFence gk)
          check $ lastFence == curFence
          let newFence = curFence+1
          writeTVar (gCommiting gk) newFence
          return $ (a, Just newFence)
      else do
          always $ checkLastFence gk lastFence
          return (a,Nothing)

-- TODO: I should check better that the ticket is valid.
commitExclusive :: Gatekeeper -> Ticket -> STM ()
commitExclusive gk ticket = do
    always $ (== ticket) <$> readTVar (gCommiting gk)
    putTMVar (gFence gk) ticket
