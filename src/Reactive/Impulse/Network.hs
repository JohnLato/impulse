
{-# OPTIONS_GHC -Wall #-}
module Reactive.Impulse.Network (
  Network (..)
, compileNetwork
, startNetwork
, pauseNetwork
) where

import Reactive.Impulse.Core
import Reactive.Impulse.Internal.Types
import Reactive.Impulse.Chain
import Reactive.Impulse.Graph

import Control.Applicative
import Control.Lens
import Control.Monad.RWS
import Control.Monad.State
import Control.Concurrent.STM

import qualified Data.IntMap as IM

import System.Mem.Weak
import GHC.Conc.Sync (unsafeIOToSTM)

-----------------------------------------------------------
-- Network, starting/stopping.

-- TODO: should begin paused, then we can start running the network separately
compileNetwork :: SGen a -> IO (a,Network)
compileNetwork net = do
    (a,sgstate) <- runStateT net mempty
    _nInputs <- compileHeadMap sgstate
    _nPaused <- newTVarIO Nothing
    _nActions <- newTVarIO (return ())
    runningGraph <- initialRunningDynGraph
    let network = Network _nInputs runningGraph _nPaused _nActions
        builder = buildTopChains (sgstate^.outputs)
    atomically $ do
        initialActions <- dynUpdateGraph network builder
        writeTVar _nActions initialActions
        pauseNetwork' network
    return (a, network)

pauseNetwork :: Network -> IO ()
pauseNetwork = atomically . pauseNetwork'

pauseNetwork' :: Network -> STM ()
pauseNetwork' net = do
    net ^! nPaused.act readTVar._Nothing.act (\_ -> do
          inpMap <- net ^! nInputs.act readTVar
          pausedMap <- traverse pauseInput inpMap
          writeTVar (net^.nPaused)
                    (Just . NetworkPausing $ IM.mapMaybe id pausedMap) )
  where
    pauseInput (EInput weak) = do
        pusher'm <- unsafeIOToSTM $ deRefWeak weak
        traverse (\tv -> do
            origFn <- readTVar tv
            writeTVar tv (const $ return ())
            return $ PInput tv origFn) pusher'm

startNetwork :: Network -> IO ()
startNetwork net = join . atomically $ do
    net ^! nPaused.act readTVar._Just.npPausedInputs.act (\np -> do
            mapMOf_ traverse (\(PInput tv orig) -> writeTVar tv orig) np
            writeTVar (net^.nPaused) Nothing)
    net ^! nActions.act (\tv -> readTVar tv <* writeTVar tv (return ()))
