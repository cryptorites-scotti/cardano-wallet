{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
module Cardano.Wallet.Network.LightSpec
    ( spec
    ) where

import Prelude

import Cardano.Wallet.Network
    ( ChainFollower (..) )
import Cardano.Wallet.Network.Light
    ( LightBlocks, LightSyncSource (..), hoistLightSyncSource, lightSync )
import Cardano.Wallet.Primitive.BlockSummary
    ( BlockSummary (..) )
import Cardano.Wallet.Primitive.Types
    ( BlockHeader (..)
    , ChainPoint (..)
    , chainPointFromBlockHeader
    , isGenesisBlockHeader
    )
import Cardano.Wallet.Primitive.Types.Hash
    ( Hash (..) )
import Control.Monad
    ( ap, forever, void )
import Control.Monad.Class.MonadTimer
    ( MonadDelay (..) )
import Control.Monad.Trans.State
    ( State, get, modify, runState )
import Control.Tracer
    ( nullTracer )
import Data.Foldable
    ( find )
import Data.List.NonEmpty
    ( NonEmpty (..) )
import Data.Quantity
    ( Quantity (..) )
import Data.Void
    ( Void )
import Test.Hspec
    ( Spec, describe, it )
import Test.QuickCheck
    ( Arbitrary (..)
    , Gen
    , Property
    , choose
    , frequency
    , property
    , sized
    , (===)
    )

import qualified Data.ByteString.Char8 as B8
import qualified Data.List as L
import qualified Data.List.NonEmpty as NE

spec :: Spec
spec =
    describe "lightSync" $
        it "lightSync === full sync  for chain following" $
            property prop_followLightSync

{-------------------------------------------------------------------------------
    Properties
-------------------------------------------------------------------------------}
prop_followLightSync :: ChainHistory -> Property
prop_followLightSync history =
    eval (fullSync follower)
  ===
    eval (lightSync nullTracer lightSource follower)
  where
    follower = mkFollower updateFollower
    eval action =
        latest $ evalMockMonad action history $ initFollowerState history
    fromReader :: (MockChain -> a) -> MockMonad s a
    fromReader get' = do
        _ <- tick
        get' <$> getChain
    lightSource = hoistLightSyncSource fromReader mkLightSyncSourceMock

{-------------------------------------------------------------------------------
    MockChain
    * … is a list of 'BlockHeader's
    * … can be generated by random roll-forward and roll-backward
-------------------------------------------------------------------------------}
type MockChain = NonEmpty Block
type Block = BlockHeader

-- | 'LightSyncSource' that reads from a 'MockChain'.
mkLightSyncSourceMock
    :: LightSyncSource ((->) MockChain) Block addr ()
mkLightSyncSourceMock = LightSyncSource
    { stabilityWindow = fromIntegral mockStabilityWindow
    , getHeader = id
    , getTip = NE.head
    , isConsensus = \pt -> any ((pt ==) . toPoint)
    , getBlockHeaderAtHeight = \height ->
        find ((height ==) . toHeight)
    , getBlockHeaderAt = \pt ->
        find ((pt ==) . toPoint)
    , getNextBlocks = \pt chain ->
        case NE.span ((pt /=) . toPoint) chain of
            (_,[]) -> Nothing -- point does not exist
            (xs,_) -> Just (reverse xs)
    , getAddressTxs = \_ _ _ -> pure ()
    }
  where
    toPoint = chainPointFromBlockHeader
    toHeight = fromIntegral . fromEnum . blockHeight

data ChainHistory = ChainHistory !MockChain ![(DeltaChain, MockChain)]
    deriving Eq

instance Show ChainHistory where
    show (ChainHistory c0 deltas) = unwords $ L.intersperse "->"
        [ show s
        | b <- c0 : map snd deltas
        , let Hash s = headerHash $ NE.head b
        ]

instance Arbitrary ChainHistory where
    arbitrary = sized genChainHistory

genChainHistory :: Int -> Gen ChainHistory
genChainHistory n = go 1 chain0 (ChainHistory chain0 [])
  where
    chain0 = genesisBlock :| []
    go j c1 (ChainHistory c0 deltas)
        | j >= n = pure $ ChainHistory c0 (reverse deltas)
        | otherwise = do
            (delta, c2) <- genDeltaChain j c1
            ds <- splitForward delta
            go (j+1) c2 $ ChainHistory c0 $ [ (d,c2) | d <- reverse ds ] ++ deltas

    splitForward (Forward blocks tip) = do
        blockss <- subsequences $ NE.toList blocks
        pure $ Forward <$> blockss <*> pure tip
    splitForward x = pure [x]

-- | Randomly split a list into subsequences.
subsequences :: [a] -> Gen [NonEmpty a]
subsequences [] = pure []
subsequences xs = do
    n <- choose (1,length xs)
    (NE.fromList (take n xs) :) <$> subsequences (drop n xs)


data DeltaChain
    = Forward (NonEmpty Block) BlockHeader
    | Backward BlockHeader
    | Idle
    deriving (Eq,Show)

genesisBlock :: Block
genesisBlock = BlockHeader
    { slotNo = 0
    , blockHeight = Quantity 0
    , headerHash = mockHash 0
    , parentHeaderHash = Nothing
    }

mockHash :: Int -> Hash "BlockHeader"
mockHash = Hash . B8.pack . show

mockStabilityWindow :: Int
mockStabilityWindow = 5

genDeltaChain :: Int -> MockChain -> Gen (DeltaChain, MockChain)
genDeltaChain n chain1 = frequency [(2,forward), (1,backward)]
  where
    tip1 = NE.head chain1
    forward = do
        let newblock = BlockHeader
                { slotNo = succ (slotNo tip1)
                , blockHeight = succ (blockHeight tip1)
                , headerHash = mockHash n
                , parentHeaderHash = Just $ headerHash tip1
                }
            chain2 = newblock NE.<| chain1
        pure (Forward (newblock :| []) (NE.head chain2), chain2)
    backward = do
        m <- choose (0, min (NE.length chain1 - 1) mockStabilityWindow)
        let chain2 = NE.fromList (NE.drop m chain1)
        pure (Backward (NE.head chain2), chain2)

{-------------------------------------------------------------------------------
    Monad that mocks time evolution of a MockChain.
    Also keeps track of the state of potential chain followers.
-------------------------------------------------------------------------------}
data Free f a
    = Free (f (Free f a))
    | Pure a

instance Functor f => Functor (Free f) where
    fmap g (Pure a)  = Pure (g a)
    fmap g (Free f) = Free (fmap g <$> f)

instance Functor f => Applicative (Free f) where
    pure  = Pure
    (<*>) = ap

instance Functor f => Monad (Free f) where
    (Pure x) >>= k = k x
    (Free f) >>= k = Free ((>>= k) <$> f)

type MockMonad s = Free (MockAction s)

data MockAction s k where
    Wait
        :: (() -> k) -> MockAction s k
    Tick
        :: (DeltaChain -> k) -> MockAction s k
        -- ^ Time step where the 'MockChain' evolves.
    GetChain
        :: (MockChain -> k) -> MockAction s k
        -- ^ Get current state of the 'MockChain'.
    UpdateFollower
        :: State s a -> (a -> k) -> MockAction s k
        -- ^ Embedded state of a chain follower.

instance Functor (MockAction s) where
    fmap f (Wait k) = Wait (f . k)
    fmap f (Tick k) = Tick (f . k)
    fmap f (GetChain k) = GetChain (f . k)
    fmap f (UpdateFollower s k) = UpdateFollower s (f . k)

wait :: MockMonad s ()
wait = Free (Wait Pure)

tick :: MockMonad s DeltaChain
tick = Free (Tick Pure)

getChain :: MockMonad s MockChain
getChain = Free (GetChain Pure)

updateFollower :: State s a -> MockMonad s a
updateFollower action = Free (UpdateFollower action Pure)

instance MonadDelay (MockMonad s) where
    threadDelay _ = wait

-- | Evaluate a 'MockMonad' action on a given 'ChainHistory'.
evalMockMonad :: MockMonad s a -> ChainHistory -> s -> s
evalMockMonad action0 (ChainHistory chain0 deltas0) s0
    = go action0 s0 chain0 deltas0
  where
    go (Pure _) s _ _ = s -- monad has finished
    go (Free action) s chain deltas = case action of
        Wait k -> case deltas of
            [] -> s -- chain will not change anymore
            _ -> go (k ()) s chain deltas
        Tick k -> case deltas of
            [] -> go (k Idle) s chain deltas
            ((d,chain2):ds) -> go (k d) s chain2 ds
        GetChain k ->
            go (k chain) s chain deltas
        UpdateFollower act k ->
            let (a, s2) = runState act s
            in  go (k a) s2 chain deltas

-- | Run a 'ChainFollower' based on the full synchronization.
fullSync
    :: ChainFollower (MockMonad s) ChainPoint BlockHeader
        (LightBlocks (MockMonad s) Block addr txs)
    -> MockMonad s Void
fullSync follower = forever $ do
    delta <- tick
    case delta of
        Idle -> wait
        Forward bs tip -> rollForward follower (Left bs) tip
        Backward target -> void $
            rollBackward follower $ chainPointFromBlockHeader target

{-------------------------------------------------------------------------------
    Implementation of a ChainFollower
-------------------------------------------------------------------------------}
-- | List of checkpoints, ordered from latest to oldest.
type FollowerState = NonEmpty BlockHeader

initFollowerState :: ChainHistory -> FollowerState
initFollowerState (ChainHistory chain0 _) = NE.head chain0 :| []

latest :: FollowerState -> BlockHeader
latest = NE.head

-- | Make a 'ChainFollower' for 'FollowerState'.
mkFollower
    :: Monad m
    => (forall a. State FollowerState a -> m a)
    -> ChainFollower m ChainPoint BlockHeader
        (LightBlocks m Block addr txs)
mkFollower lift = ChainFollower
    { readChainPoints = lift $ map chainPointFromBlockHeader . NE.toList <$> get
    , rollForward = \blocks _tip -> lift $ modify $ \s -> case blocks of
        Left bs ->
            if latest s `isParentOf` NE.head bs
                then NE.reverse bs <> s
                else error "lightSync: Nonempty Block out of order"
        Right BlockSummary{from,to} ->
            if latest s `isParentOf` from
                then to NE.<| s
                else error "lightSync: BlockSummary out of order"
    , rollBackward = \target -> lift $ do
        modify $ NE.fromList . NE.dropWhile (`after` target)
        chainPointFromBlockHeader . NE.head <$> get
    }
  where
    bh `after` ChainPointAtGenesis = not (isGenesisBlockHeader bh)
    bh `after` (ChainPoint slot _) = slotNo bh > slot

    isParentOf :: BlockHeader -> BlockHeader -> Bool
    isParentOf parent = (== Just (headerHash parent)) . parentHeaderHash
