{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RecursiveDo #-}

{-# OPTIONS_GHC -Wall #-}
-- The 'Chain' is the main runtime representation of a reactive network.
-- An input is connected to several chains, each of which is a series of
-- IO actions (pushes), culminating in either a 'reactimate' or updating
-- a Behavior.
-- All reactimate chains are performed in the order of the reactimate calls,
-- then all behavior updates are performed (in an arbitrary order).

module Reactive.Impulse.Chain

where

import Reactive.Impulse.Core

import Control.Applicative
import Control.Arrow
import Control.Monad.State.Lazy
import Control.Monad.Trans.Maybe

import Data.IORef
import Data.IntMap (IntMap)
import qualified Data.IntMap as IM
import Data.List (foldl')
import Data.Maybe
import Data.Monoid

import System.Mem.StableName
import Unsafe.Coerce

-----------------------------------------------------------

data Chain r a where
    CEvent :: Chain r a -> Chain r a
    CMap   :: (a -> b)  -> Chain r b -> Chain r a
    COut   :: Chain r r
    CAcc   :: a -> CBehavior a   -> Chain r (a->a)
    CApply :: CBehavior (a -> b) -> Chain r b -> Chain r a

-- A CBehavior is the representation of a Behavior within a Chain.
-- TODO: most of the time we can't push to a behavior, so we should
-- probably differentiate between the two cases.
type CBehavior a = (IO a, (a -> a) -> IO ())

makeCBehavior :: IORef a -> CBehavior a
makeCBehavior ref = (readIORef ref, modd)
  where
    modd f = atomicModifyIORef' ref (\l -> let a' = f l in (a',a')) >>= (`seq` return ())

-- Differentiate between the two types of terminals, reactimated Events
-- and accumulating Behaviors.
data CTerminalType = CTTerm | CTBehavior deriving (Eq, Show, Ord)

-- wrap chains to put them in a map
data EChain where
    EChain :: Label -> CTerminalType -> Chain r a -> EChain

data EBehavior where
    EBehavior :: Label -> CBehavior a -> EBehavior

-----------------------------------------------------------

-- The ChainM monoid keeps track of bookkeeping items while chains are being
-- constructed from the graph.
type ChainM = StateT (EdgeCount,(Chains,Behaviors)) IO

-- The downstream chains for each node in a graph.
data ChainNode = ChainNode
    { cnTerminals :: [ EChain ]
    , cnBehaviors :: [ EChain ]
    }

instance Monoid ChainNode where
    mempty = ChainNode [] []
    ChainNode l1 l2 `mappend` ChainNode r1 r2 = ChainNode (l1 <> r1) (l2 <> r2)

type Chains = IntMap ChainNode
type Behaviors = IntMap EBehavior

chainExists :: Label -> ChainM Bool
chainExists lbl = IM.member lbl . fst . snd <$> get

addChain :: EChain -> ChainM ()
addChain e@(EChain lbl ctyp _) = modify $ second . first $ IM.insertWith mappend lbl cn
  where
    cn = case ctyp of
        CTTerm -> ChainNode {cnTerminals = [e], cnBehaviors = [ ]}
        CTBehavior  -> ChainNode {cnTerminals = [ ], cnBehaviors = [e]}

addBehavior :: EBehavior -> ChainM ()
addBehavior e@(EBehavior lbl _) = modify $ (second . second) $ IM.insert lbl e

lookupChain :: Label -> ChainM (Maybe ChainNode)
lookupChain lbl = IM.lookup lbl . fst . snd <$> get

lookupBehavior :: Label -> ChainM (Maybe EBehavior)
lookupBehavior lbl = IM.lookup lbl . snd . snd <$> get

-----------------------------------------------------

-- We need to fully process all chains from a node before we can move up to
-- its parent.  The first step of the algorithm is to count the number of
-- output edges from each node.  We can decrement the count as children
-- are encountered, so when a node has no unprocessed children it's ready
-- to be processed itself.

type EdgeCount = IntMap Int

-- count the number of out edges from a node.
eOutCount :: Event a -> EdgeCount
eOutCount e = go IM.empty e
  where
    go :: EdgeCount -> Event k -> EdgeCount
    go mp = \case
        -- assume we've come from somewhere, except for EOut nodes
        (EIn lbl) -> ins lbl mp
        (EOut lbl prev)    -> go (IM.insert lbl 0 mp) prev
        (ENull lbl prev)   -> go (ins lbl mp) prev
        (EMap lbl _ prev)  -> go (ins lbl mp) prev
        (EUnion lbl p1 p2) -> go (go (ins lbl mp) p1) p2
        (EApply lbl p b)   -> go (goB (ins lbl mp) b) p
    goB :: EdgeCount -> Behavior k -> EdgeCount
    goB mp = \case
        -- BAcc,BPure are terminals like EOut, so always use 0 out edges
        BAcc lbl _ prev    -> go (IM.insert lbl 0 mp) prev
        BPure lbl _        -> IM.insert lbl 0 mp
        BMap lbl _ b       -> goB (ins lbl mp) b
        BApp lbl f b       -> goB (goB (ins lbl mp) f) b
    ins :: Label -> EdgeCount -> EdgeCount
    ins lbl = IM.insertWith (+) lbl 1

calcAllOutEdges :: [ Event k ] -> EdgeCount
calcAllOutEdges = foldl' (\acc -> IM.unionWith (+) acc . eOutCount) IM.empty

decEdgeCount :: Label -> ChainM ()
decEdgeCount = modify . first . IM.adjust (subtract 1)

-- terminals always have a zero out count, so we have a convenience function
-- for that case.
zeroEdgeCount :: Label -> ChainM ()
zeroEdgeCount = modify . first . flip IM.insert 0

-----------------------------------------------------

-- We keep a queue of nodes remaining to be processed.
-- when a node is first encountered, if the nodecount <= 0,
-- it's processed and the parent nodes pushed onto the front.
-- If the nodecount is >0, it is popped and enqueued at the back.
--
-- operationally, this queue is kept as a recursive (MaybeT ChainM).
-- An action that returns Nothing is completed. If it returns a new
-- (MaybeT ChainM) action, that action is enqueued.
--
-- TODO:
-- We could check for non-termination by checking the edgecount map at
-- each step.  If the edgecount hasn't changed, and no actions have
-- completed, then we're likely in a non-terminating cycle.  I think this
-- can only happen from obvious cyclic cases like
-- 
-- > let e1 = e2
-- >     e2 = e1
--

newtype Fix f = Fx { unFix :: f (Fix f) }

type ProcessQueue = Fix (MaybeT ChainM)

-- interleave a bunch of ProcessQueue items.
interleave :: [ProcessQueue] -> ProcessQueue
interleave stuff = Fx $ do
    let stateMs = map (runMaybeT . unFix) stuff
    nexts <- lift $ catMaybes <$> sequence stateMs
    -- if there's nothing left to do, just mzero now.
    guard (not $ null nexts)
    return $ interleave nexts 

-- Evaluate a ProcessQueue until everything is done.
-- this could fail to terminate, see the notes above ProcessQueue.
run :: ProcessQueue -> ChainM ()
run (Fx f) = do
    stm <- runMaybeT f
    case stm of
        Nothing -> return ()
        Just c  -> run c

-- | Create all Chains for a list of output Events.
buildChains :: [ Event (IO ()) ] -> ChainM ()
buildChains = run . interleave . map (makeStack Nothing)
  where
    makeStackB :: Behavior k -> ChainM (CBehavior k, ProcessQueue)
    makeStackB = \case
        -- for BAcc, the child label doesn't matter, since we
        -- don't need its chain
        BAcc lbl a0 prevE -> lookupBehavior lbl >>= \case
            Just (EBehavior lbl' beh)
                | lbl == lbl' -> return (unsafeCoerce beh, Fx mzero)
                | otherwise -> error $ "buildChains: labels didn't match for BAcc!"
            Nothing -> do
                mTrace $ "BAcc " ++ show lbl
                cbeh <- liftIO $ makeCBehavior <$> newIORef a0
                -- BAcc is both a terminal push action and an initial pull
                -- so it goes in both chain and behavior maps
                zeroEdgeCount lbl
                addChain $ EChain lbl CTBehavior $ CAcc a0 cbeh
                addBehavior $ EBehavior lbl cbeh
                -- the pushing event needs to have this child added
                return (cbeh, makeStack (Just lbl) prevE)
        BPure _l a -> return ((return a, const $ error "can't write to Pure"), Fx mzero)
        BMap lbl f prevB -> lookupBehavior lbl >>= \case
          Just (EBehavior lbl' cbeh)
              | lbl == lbl' -> return $ unsafeCoerce cbeh
              | otherwise -> error "buildChains: labels don't match for BMap"
          Nothing -> do
              mTrace $ "BMap " ++ show lbl
              (pBeh,nextStuff) <- makeStackB prevB
              let pRead = fst pBeh
              -- always force stuff before calling makeStableName
              !p0 <- liftIO $ pRead
              cache <- liftIO $ do
                  stn <- makeStableName p0
                  newIORef (stn,f p0)
              let cbeh = (cRead, \_ -> error "can't write directly to BMap")
                  cRead = do
                      (stn,c) <- readIORef cache
                      !p   <- pRead
                      stn' <- makeStableName p
                      if stn == stn'
                          then return c
                          else let c' = (f p)
                              in writeIORef cache (stn',c') >> return c'
              addBehavior $ EBehavior lbl cbeh
              return (cbeh, nextStuff)
        BApp lbl fB prevB -> lookupBehavior lbl >>= \case
          Just (EBehavior lbl' cbeh)
              | lbl == lbl' -> return $ unsafeCoerce cbeh
              | otherwise -> error "buildChains: labels don't match for BMap"
          Nothing -> do
              mTrace $ "BApp " ++ show lbl
              (pBeh,nextStuff1) <- makeStackB prevB
              (pfB, nextStuff2) <- makeStackB fB
              let pRead = fst pBeh
                  fRead = fst pfB
              -- always force stuff before calling makeStableName
              !p0 <- liftIO $ pRead
              !f0 <- liftIO $ fRead
              cache <- liftIO $ do
                  stn <- makeStableName (f0,p0)
                  newIORef (stn,f0 p0)
              let cbeh = (cRead, \_ -> error "can't write directly to BMap")
                  cRead = do
                      (stn,c) <- readIORef cache
                      !p   <- pRead
                      !f   <- fRead
                      stn' <- makeStableName (f,p)
                      if stn == stn'
                          then return c
                          else let c' = (f p)
                              in writeIORef cache (stn',c') >> return c'
              addBehavior $ EBehavior lbl cbeh
              return (cbeh, interleave [nextStuff1,nextStuff2])

    makeStack :: Maybe Label -> Event k -> ProcessQueue
    makeStack Nothing (EOut lbl prev) = Fx $ do
        let chn = COut :: Chain (IO ()) (IO ())
        lift $ decEdgeCount lbl >> addChain (EChain lbl CTTerm chn)
        return $ makeStack (Just lbl) prev
    makeStack Nothing e = error $ "buildChains: got non-terminal with no child info: " ++ show (eLabel e)
    makeStack (Just childLbl) e = Fx $ do
        curEdges <- fst <$> get
        case (IM.lookup childLbl curEdges) of
            -- when edgecount = 0, we can process a node
            -- otherwise we need to wait until all edges are complete
            Just n
              | n <= 0 -> case e of
                EOut _ _ ->
                    error "buildChains: got a non-terminal EOut"
                EIn lbl -> do
                    mTrace $ "EIn " ++ show lbl
                    lift $ decEdgeCount lbl >> addChains lbl CEvent e childLbl
                    mzero
                ENull lbl prev -> do
                    mTrace $ "ENull " ++ show lbl
                    lift $ decEdgeCount lbl >> addChains lbl CEvent e childLbl
                    unFix $ makeStack (Just lbl) prev
                EMap lbl f prev -> do
                    mTrace $ "EMap " ++ show lbl
                    lift $ decEdgeCount lbl >> addChains lbl (CMap f) e childLbl
                    unFix $ makeStack (Just lbl) prev
                EUnion lbl prev1 prev2 -> do
                    lift $ decEdgeCount lbl >> addChains lbl id e childLbl
                    -- we can't just run the next blocks, because then
                    -- we might terminate early.  This way we thread the
                    -- state through and postpone the continuation logic
                    -- until later
                    let nxt1 = makeStack (Just lbl) prev1
                        nxt2 = makeStack (Just lbl) prev2
                    unFix $ interleave [nxt1,nxt2]
                EApply lbl prevE beh -> do
                    mTrace $ "EApply " ++ show lbl
                    let nxtE = makeStack (Just lbl) prevE
                    (cbeh, nxtB) <- lift $ makeStackB beh
                    lift $ decEdgeCount lbl
                         >> addChains lbl (CApply cbeh) e childLbl
                    unFix $ interleave [nxtB, nxtE]
              | otherwise -> return $ makeStack (Just childLbl) e
            Nothing -> error $ "buildChains: no edgecount for: " ++ show (eLabel e)
      
chainsFrom :: f a -> Label -> (Chains,Behaviors)
           -> ([Chain r a],[Chain r a])
chainsFrom _ lbl (chainMp,_behMp) =
    let ChainNode{..} = fromMaybe (error errMsg) $ IM.lookup lbl chainMp
        errMsg = "no chains for " ++ show lbl
    in (map (\(EChain _ _ c) -> unsafeCoerce c) cnTerminals
       ,map (\(EChain _ _ c) -> unsafeCoerce c) cnBehaviors)

-- this should be let-bound in buildChains', but I haven't
-- bothered to figure out the correct type for it there (WRT maps)
addChains
   :: Label
   -> (Chain r a -> Chain r b)
   -> f a
   -> Label
   -> ChainM ()
addChains lbl fn e chldLbl = do
    (childE,childB) <- chainsFrom e chldLbl . snd <$> get
    mapM_ (addChain . EChain lbl CTTerm . fn) childE
    mapM_ (addChain . EChain lbl CTBehavior . fn) childB
-----------------------------------------------------

whenM :: Monad m => m Bool -> m () -> m ()
whenM p act = p >>= \case { True -> act; False -> return () }
mTrace :: MonadIO m => String -> m ()
mTrace = const $ return ()
-- mTrace = liftIO . traceIO

compileChain :: Chain r a -> IO ((r -> IO ()) -> a -> IO ())
compileChain (CEvent next) = mTrace "cc next" >> compileChain next
compileChain (CMap f next) = do
    mTrace "cc cmap"
    next' <- compileChain next
    return $ \sink -> next' sink . f
compileChain COut = mTrace "COut" >> return ($)
compileChain (CAcc a0 (_reader,writer)) = do
    mTrace "cc cacc"
    writer (const a0)
    return $ \_sink f -> writer f
compileChain (CApply (reader,_) next) = do
    mTrace "cc capply"
    next' <- compileChain next
    return $ \sink a -> do
        f <- reader
        next' sink $! f a
{-
compileChain (CDynE next) = do
    next' <- compileChain next
    return $ \sink dynE -> do
        prev <- compileChain dynE
        prev sink (error "compileChain: dynE not right")
-}
