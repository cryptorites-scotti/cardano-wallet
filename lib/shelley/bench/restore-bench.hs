{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoMonoLocalBinds #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-unused-local-binds #-}
{-# OPTIONS_GHC -Wno-unused-do-bind #-}

{- HLINT ignore "Redundant pure" -}


-- | Benchmark measuring how long restoration takes for different wallets.
--
-- Easiest run using
-- @
--     $ export NODE_DB="node-db-testnet"
--     $ nix build .#benchmarks/cardano-wallet/restore -o restore && ./restore/bin/restore testnet
-- @
--
-- or
-- @
--     $ ./.buildkite/bench-restore.sh shelley testnet
-- @
--
-- since it relies on lots of configuration most most easily retrieved with nix.
--
-- You can also connect to an already-running node using:
-- @
--      stack bench cardano-wallet:bench:restore
--          --ba 'mainnet -c $CONFIGURATION_DIR
--          --running-node $CARDANO_NODE_SOCKET_PATH
-- @
--
-- This makes iteration easy, but requires you to have the configuration
-- directory layout setup correctly, and to know how to start a node.

module Main where

import Prelude

import Cardano.Address.Derivation
    ( XPrv )
import Cardano.BM.Data.Severity
    ( Severity (..) )
import Cardano.BM.Data.Tracer
    ( HasPrivacyAnnotation (..), HasSeverityAnnotation (..) )
import Cardano.BM.Trace
    ( Trace, nullTracer )
import Cardano.Mnemonic
    ( SomeMnemonic (..), entropyToMnemonic )
import Cardano.Wallet
    ( WalletLayer (..), WalletWorkerLog (..), networkLayer )
import Cardano.Wallet.Api.Types
    ( toApiUtxoStatistics )
import Cardano.Wallet.BenchShared
    ( RestoreBenchArgs (..)
    , Time
    , argsNetworkDir
    , bench
    , execBenchWithNode
    , initBenchmarkLogging
    , runBenchmarks
    )
import Cardano.Wallet.CoinSelection
    ( SelectionStrategy (..), selectionDelta )
import Cardano.Wallet.DB
    ( DBLayer )
import Cardano.Wallet.DB.Sqlite
    ( PersistAddressBook, withDBLayer )
import Cardano.Wallet.Logging
    ( trMessageText )
import Cardano.Wallet.Network
    ( ChainFollowLog (..)
    , ChainFollower (ChainFollower, readChainPoints, rollBackward, rollForward)
    , ChainSyncLog (..)
    , NetworkLayer (..)
    )
import Cardano.Wallet.Primitive.AddressDerivation
    ( Depth (..)
    , NetworkDiscriminant (..)
    , NetworkDiscriminantVal (..)
    , PaymentAddress
    , PersistPrivateKey
    , WalletKey
    , digest
    , publicKey
    )
import Cardano.Wallet.Primitive.AddressDerivation.Byron
    ( ByronKey )
import Cardano.Wallet.Primitive.AddressDerivation.Shelley
    ( ShelleyKey )
import Cardano.Wallet.Primitive.AddressDiscovery
    ( CompareDiscovery
    , GenChange (..)
    , IsOurs
    , IsOwned
    , KnownAddresses
    , MaybeLight
    )
import Cardano.Wallet.Primitive.AddressDiscovery.Random
    ( RndAnyState, mkRndAnyState )
import Cardano.Wallet.Primitive.AddressDiscovery.Sequential
    ( AddressPoolGap
    , SeqAnyState (..)
    , mkAddressPoolGap
    , mkSeqAnyState
    , purposeCIP1852
    )
import Cardano.Wallet.Primitive.Model
    ( Wallet, currentTip, getState, totalUTxO )
import Cardano.Wallet.Primitive.Passphrase
    ( Passphrase (..) )
import Cardano.Wallet.Primitive.Slotting
    ( TimeInterpreter, neverFails )
import Cardano.Wallet.Primitive.SyncProgress
    ( SyncProgress (..), SyncTolerance, mkSyncTolerance )
import Cardano.Wallet.Primitive.Types
    ( Block (..)
    , BlockHeader (..)
    , GenesisParameters (..)
    , NetworkParameters (..)
    , SlotNo (..)
    , SortOrder (..)
    , WalletId (..)
    , WalletName (..)
    , chainPointFromBlockHeader
    )
import Cardano.Wallet.Primitive.Types.Address
    ( Address (..) )
import Cardano.Wallet.Primitive.Types.Coin
    ( Coin (..) )
import Cardano.Wallet.Primitive.Types.RewardAccount
    ( RewardAccount )
import Cardano.Wallet.Primitive.Types.Tx
    ( TxOut (..) )
import Cardano.Wallet.Primitive.Types.UTxO
    ( UTxOStatistics (..), computeUtxoStatistics, log10 )
import Cardano.Wallet.Shelley
    ( SomeNetworkDiscriminant (..) )
import Cardano.Wallet.Shelley.Compatibility
    ( CardanoBlock
    , HasNetworkId (..)
    , NodeToClientVersionData
    , StandardCrypto
    , emptyGenesis
    , fromCardanoBlock
    , numberOfTransactionsInBlock
    )
import Cardano.Wallet.Shelley.Launch
    ( CardanoNodeConn, NetworkConfiguration (..), parseGenesisData )
import Cardano.Wallet.Shelley.Network.Node
    ( withNetworkLayer )
import Cardano.Wallet.Shelley.Transaction
    ( TxWitnessTagFor (..), newTransactionLayer )
import Cardano.Wallet.Transaction
    ( defaultTransactionCtx )
import Cardano.Wallet.Unsafe
    ( unsafeMkEntropy, unsafeMkPercentage, unsafeRunExceptT )
import Control.Arrow
    ( first )
import Control.DeepSeq
    ( NFData )
import Control.Monad
    ( forM, forM_, void )
import Control.Monad.IO.Class
    ( MonadIO (..) )
import Control.Monad.Trans.Except
    ( runExceptT, withExceptT )
import Control.Tracer
    ( Tracer (..), traceWith )
import Crypto.Hash.Utils
    ( blake2b256 )
import Data.Aeson
    ( ToJSON (..), genericToJSON, (.=) )
import Data.Functor.Contravariant
    ( contramap )
import Data.Generics.Internal.VL.Lens
    ( (^.) )
import Data.List
    ( foldl' )
import Data.Proxy
    ( Proxy (..) )
import Data.Quantity
    ( Percentage (..), Quantity (..) )
import Data.Text
    ( Text )
import Data.Text.Class
    ( ToText (..) )
import Data.Time
    ( UTCTime, diffUTCTime )
import Data.Time.Clock.POSIX
    ( POSIXTime, getCurrentTime, utcTimeToPOSIXSeconds )
import Data.Word
    ( Word32 )
import Fmt
    ( Buildable
    , blockListF'
    , build
    , genericF
    , nameF
    , pretty
    , (+|)
    , (+||)
    , (|+)
    , (||+)
    )
import GHC.Conc
    ( retry )
import GHC.Generics
    ( Generic )
import GHC.TypeLits
    ( KnownNat, Nat, natVal )
import Numeric
    ( fromRat, showFFloat )
import Ouroboros.Network.Client.Wallet
    ( PipeliningStrategy, tunedForMainnetPipeliningStrategy )
import Say
    ( sayErr )
import System.Exit
    ( exitWith )
import System.FilePath
    ( (</>) )
import System.IO
    ( IOMode (..), hFlush, withFile )
import Type.Reflection
    ( Typeable )
import UnliftIO
    ( async, atomically, cancel, newTVarIO, readTVar, readTVarIO, writeTVar )
import UnliftIO.Concurrent
    ( forkIO, threadDelay )
import UnliftIO.Exception
    ( evaluate, throwString )
import UnliftIO.Temporary
    ( withSystemTempFile )

import qualified Cardano.Wallet as W
import qualified Cardano.Wallet.DB.Sqlite as Sqlite
import qualified Cardano.Wallet.Primitive.AddressDerivation.Byron as Byron
import qualified Cardano.Wallet.Primitive.AddressDerivation.Shelley as Shelley
import qualified Cardano.Wallet.Primitive.Types.TokenBundle as TokenBundle
import qualified Cardano.Wallet.Primitive.Types.UTxOIndex as UTxOIndex
import qualified Cardano.Wallet.Primitive.Types.UTxOSelection as UTxOSelection
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

main :: IO ()
main = execBenchWithNode argsNetworkConfig cardanoRestoreBench >>= exitWith

{-------------------------------------------------------------------------------
                                Shelley benchmarks
-------------------------------------------------------------------------------}

argsNetworkConfig :: RestoreBenchArgs -> NetworkConfiguration
argsNetworkConfig args = case argNetworkName args of
    "mainnet" ->
        MainnetConfig
    _ ->
        TestnetConfig (argsNetworkDir args </> "genesis-byron.json")

-- | Run all available benchmarks.
cardanoRestoreBench
    :: Trace IO Text
    -> NetworkConfiguration
    -> CardanoNodeConn
    -> IO ()
cardanoRestoreBench tr c socketFile = do
    (SomeNetworkDiscriminant networkProxy, np, vData, _b)
        <- unsafeRunExceptT $ parseGenesisData c

    (_, walletTr) <- initBenchmarkLogging "wallet" Notice

    let network = networkDescription networkProxy
    sayErr $ "Network: " <> network
    prepareNode (trMessageText tr) networkProxy socketFile np vData

    let benchRestoreMultipleWallets nWallets target pipelinings = do
            let targetStr = T.pack $ showFFloat Nothing
                    (fromRational @Double $ getPercentage target) ""
            bench_restoration @_ @ShelleyKey
                pipelinings
                networkProxy
                (trMessageText tr)
                walletTr
                socketFile
                np
                vData
                (""+|nWallets|+"-wallets-to-"+|targetStr|+"")
                (map (\i -> walletSeq
                    ("w"+|i|+"") $ mkSeqAnyState' (Proxy @0) networkProxy)
                    [1..nWallets :: Int])
                False -- Don't write progress to .timelog file(s)
                target
                benchmarksSeq

    let benchRestoreRndWithOwnership p pipelinings = do
            let benchname = showPercentFromPermyriad p <> "-percent-rnd"
            bench_restoration
                pipelinings
                networkProxy
                (trMessageText tr)
                walletTr
                socketFile
                np
                vData
                benchname
                [walletRnd benchname
                    $ mkRndAnyState' p networkProxy]
                True -- Write progress to .timelog file
                (unsafeMkPercentage 1)
                benchmarksRnd

    let benchRestoreSeqWithOwnership p pipelinings = do
            let benchname = showPercentFromPermyriad p <> "-percent-seq"
            bench_restoration
                pipelinings
                networkProxy
                (trMessageText tr)
                walletTr
                socketFile
                np
                vData
                benchname
                [walletSeq benchname
                    $ mkSeqAnyState' p networkProxy]
                True -- Write progress to .timelog file
                (unsafeMkPercentage 1)
                benchmarksSeq
    let benchRestoreBaseline pipelinings = do
            let benchname = "baseline"
            bench_baseline_restoration
                pipelinings
                networkProxy
                (trMessageText tr)
                walletTr
                socketFile
                np
                vData
                benchname
                True
                (unsafeMkPercentage 1)

    runBenchmarks [
        benchRestoreBaseline tunedForMainnetPipeliningStrategy
        -- -- We restore /to/ a percentage that is low enough to be fast,
        -- -- but high enough to give an accurate enough indication of the
        -- -- to-100% time.
        , benchRestoreSeqWithOwnership (Proxy @0)
            tunedForMainnetPipeliningStrategy
        , benchRestoreSeqWithOwnership (Proxy @1)
            tunedForMainnetPipeliningStrategy
        , benchRestoreRndWithOwnership (Proxy @1)
            tunedForMainnetPipeliningStrategy
        , benchRestoreMultipleWallets 1 (unsafeMkPercentage 0.1)
            tunedForMainnetPipeliningStrategy
        , benchRestoreMultipleWallets 10 (unsafeMkPercentage 0.01)
            tunedForMainnetPipeliningStrategy
        , benchRestoreMultipleWallets 100 (unsafeMkPercentage 0.01)
            tunedForMainnetPipeliningStrategy
        ]
  where
    walletRnd
        :: Text
        -> (ByronKey 'RootK XPrv -> Int -> s)
        -> (WalletId, WalletName, s)
    walletRnd wname mkState =
        let
            seed = dummySeedFromName wname
            xprv = Byron.generateKeyFromSeed seed mempty
            wid = WalletId $ digest $ publicKey xprv
            rngSeed = 0
            s = mkState xprv rngSeed
        in
            (wid, WalletName wname, s)

    walletSeq
        :: Text
        -> ((ShelleyKey 'RootK XPrv, Passphrase "encryption")
            -> AddressPoolGap -> s
            )
        -> (WalletId, WalletName, s)
    walletSeq wname mkState =
        let
            seed = dummySeedFromName wname
            xprv = Shelley.generateKeyFromSeed (seed, Nothing) mempty
            wid = WalletId $ digest $ publicKey xprv
            Right gap = mkAddressPoolGap 20
            s = mkState (xprv, mempty) gap
        in
            (wid, WalletName wname, s)

    mkSeqAnyState'
        :: forall (p :: Nat) (n :: NetworkDiscriminant). Typeable n
        => Proxy p
        -> Proxy n
        -> (ShelleyKey 'RootK XPrv, Passphrase "encryption")
        -> AddressPoolGap
        -> SeqAnyState n ShelleyKey p
    mkSeqAnyState' _ _ credentials =
        mkSeqAnyState @p @n credentials purposeCIP1852


    mkRndAnyState'
        :: forall (p :: Nat) (n :: NetworkDiscriminant). ()
        => Proxy p
        -> Proxy n
        -> ByronKey 'RootK XPrv
        -> Int
        -> RndAnyState n p
    mkRndAnyState' _ _ = mkRndAnyState

    networkDescription :: forall n. (NetworkDiscriminantVal n) => Proxy n -> Text
    networkDescription _ = networkDiscriminantVal @n

{-------------------------------------------------------------------------------
                                  Benchmarks
-------------------------------------------------------------------------------}

data SomeBenchmarkResults where
    SomeBenchmarkResults
        :: forall result. Buildable result
        => result
        -> SomeBenchmarkResults

instance Buildable SomeBenchmarkResults where
    build (SomeBenchmarkResults results) = build results

data WalletOverview = WalletOverview
    { utxo :: UTxOStatistics
    , addresses :: Word
    , transactions :: Word
    } deriving (Show, Generic)

instance Buildable WalletOverview where
    build WalletOverview{utxo,addresses,transactions} =
        blockListF' "" id
            [ nameF "number of addresses" (build addresses)
            , nameF "number of transactions" (build transactions)
            , build utxo
            ]

instance ToJSON WalletOverview where
    toJSON WalletOverview{utxo,addresses,transactions} = Aeson.object
        [ "utxo" .= toApiUtxoStatistics utxo
        , "addresses" .= addresses
        , "transactions" .= transactions
        ]

data BenchRndResults = BenchRndResults
    { benchName :: Text
    , restoreTime :: Time
    , readWalletTime :: Time
    , listAddressesTime :: Time
    , listTransactionsTime :: Time
    , importOneAddressTime :: Time
    , importManyAddressesTime :: Time
    , estimateFeesTime :: Time
    , walletOverview :: WalletOverview
    } deriving (Show, Generic)

instance Buildable BenchRndResults where
    build = genericF

instance ToJSON BenchRndResults where
    toJSON = genericToJSON Aeson.defaultOptions

benchmarksRnd
    :: forall (n :: NetworkDiscriminant) s k p.
        ( s ~ RndAnyState n p
        , k ~ ByronKey
        , PaymentAddress n k
        , NetworkDiscriminantVal n
        , KnownNat p
        )
    => Proxy n
    -> WalletLayer IO s k
    -> WalletId
    -> WalletName
    -> Text
    -> Time
    -> IO BenchRndResults
benchmarksRnd _ w wid wname benchname restoreTime = do
    ((cp, pending), readWalletTime) <- bench "read wallet" $ do
        (cp, _, pending) <- unsafeRunExceptT $ W.readWallet w wid
        pure (cp, pending)

    (utxo, _) <- bench "utxo statistics" $ do
        pure $ computeUtxoStatistics log10 (totalUTxO pending cp)

    (addresses, listAddressesTime) <- bench "list addresses"
        $ fmap (fromIntegral . length)
        $ unsafeRunExceptT
        $ W.listAddresses w wid (const pure)

    (transactions, listTransactionsTime) <- bench "list transactions"
        $ fmap (fromIntegral . length)
        $ unsafeRunExceptT
        $ W.listTransactions @_ @s @k w wid Nothing Nothing Nothing Descending

    (_, estimateFeesTime) <- bench "estimate tx fee" $ do
        let out = TxOut (dummyAddress @n) (TokenBundle.fromCoin $ Coin 1)
        let txCtx = defaultTransactionCtx
        let getFee = const (selectionDelta TokenBundle.getCoin)
        (utxoAvailable, wallet, pendingTxs) <-
            unsafeRunExceptT $ W.readWalletUTxOIndex @_ @s @k w wid
        pp <- liftIO $ currentProtocolParameters (w ^. networkLayer)
        let selectAssetsParams = W.SelectAssetsParams
                { outputs = [out]
                , pendingTxs
                , randomSeed = Nothing
                , txContext = txCtx
                , utxoAvailableForInputs = UTxOSelection.fromIndex utxoAvailable
                , utxoAvailableForCollateral = UTxOIndex.toMap utxoAvailable
                , wallet
                , selectionStrategy = SelectionStrategyOptimal
                }
        let runSelection =
                W.selectAssets @_ @_ @s @k w pp selectAssetsParams getFee
        runExceptT $ withExceptT show $ W.estimateFee runSelection

    oneAddress <- genAddresses 1 cp
    (_, importOneAddressTime) <- bench "import one addresses" $ do
        runExceptT $ withExceptT show $
            W.importRandomAddresses @_ @s @k w wid oneAddress

    manyAddresses <- genAddresses 1000 cp
    (_, importManyAddressesTime) <- bench "import many addresses" $ do
        runExceptT $ withExceptT show $
            W.importRandomAddresses @_ @s @k w wid manyAddresses

    let walletOverview = WalletOverview{utxo,addresses,transactions}

    pure BenchRndResults
        { benchName = benchname
        , restoreTime
        , readWalletTime
        , listAddressesTime
        , listTransactionsTime
        , estimateFeesTime
        , importOneAddressTime
        , importManyAddressesTime
        , walletOverview
        }
  where
    genAddresses :: Int -> Wallet s -> IO [Address]
    genAddresses n cp = evaluate $ fst $ foldl'
        (\(xs, s) _ -> first (:xs) $ genChange (xprv, mempty) s)
        ([], getState cp)
        [1..n]
      where
        seed = dummySeedFromName $ getWalletName wname
        xprv = Byron.generateKeyFromSeed seed mempty

data BenchSeqResults = BenchSeqResults
    { benchName :: Text
    , restoreTime :: Time
    , readWalletTime :: Time
    , listAddressesTime :: Time
    , listTransactionsTime :: Time
    , estimateFeesTime :: Time
    , walletOverview :: WalletOverview
    } deriving (Show, Generic)

instance Buildable BenchSeqResults where
    build = genericF

instance ToJSON BenchSeqResults where
    toJSON = genericToJSON Aeson.defaultOptions

benchmarksSeq
    :: forall (n :: NetworkDiscriminant) s k p.
        ( s ~ SeqAnyState n k p
        , k ~ ShelleyKey
        , Typeable n
        , PaymentAddress n k
        , NetworkDiscriminantVal n
        , KnownNat p
        )
    => Proxy n
    -> WalletLayer IO s k
    -> WalletId
    -> WalletName
    -> Text -- ^ Bench name
    -> Time
    -> IO BenchSeqResults
benchmarksSeq _ w wid _wname benchname restoreTime = do
    ((cp, pending), readWalletTime) <- bench "read wallet" $ do
        (cp, _, pending) <- unsafeRunExceptT $ W.readWallet w wid
        pure (cp, pending)
    (utxo, _) <- bench "utxo statistics" $ do
        pure $ computeUtxoStatistics log10 (totalUTxO pending cp)

    (addresses, listAddressesTime) <- bench "list addresses"
        $ fmap (fromIntegral . length)
        $ unsafeRunExceptT
        $ W.listAddresses w wid (const pure)

    (transactions, listTransactionsTime) <- bench "list transactions"
        $ fmap (fromIntegral . length)
        $ unsafeRunExceptT
        $ W.listTransactions @_ @s @k w wid Nothing Nothing Nothing Descending

    (_, estimateFeesTime) <- bench "estimate tx fee" $ do
        let out = TxOut (dummyAddress @n) (TokenBundle.fromCoin $ Coin 1)
        let txCtx = defaultTransactionCtx
        let getFee = const (selectionDelta TokenBundle.getCoin)
        (utxoAvailable, wallet, pendingTxs) <-
            unsafeRunExceptT $ W.readWalletUTxOIndex w wid
        pp <- liftIO $ currentProtocolParameters (w ^. networkLayer)
        let selectAssetsParams = W.SelectAssetsParams
                { outputs = [out]
                , pendingTxs
                , randomSeed = Nothing
                , txContext = txCtx
                , utxoAvailableForInputs = UTxOSelection.fromIndex utxoAvailable
                , utxoAvailableForCollateral = UTxOIndex.toMap utxoAvailable
                , wallet
                , selectionStrategy = SelectionStrategyOptimal
                }
        let runSelection =
                W.selectAssets @_ @_ @s @k w pp selectAssetsParams getFee
        runExceptT $ withExceptT show $ W.estimateFee runSelection

    let walletOverview = WalletOverview{utxo,addresses,transactions}

    pure BenchSeqResults
        { benchName = benchname
        , restoreTime
        , readWalletTime
        , listAddressesTime
        , listTransactionsTime
        , estimateFeesTime
        , walletOverview
        }

data BenchBaselineResults = BenchBaselineResults
    { benchName :: Text
    , restorationTime :: Time
    } deriving (Show, Generic)

instance Buildable BenchBaselineResults where
    build = genericF

instance ToJSON BenchBaselineResults where
    toJSON = genericToJSON Aeson.defaultOptions

{- HLINT ignore bench_baseline_restoration "Use camelCase" -}
bench_baseline_restoration
    :: forall (n :: NetworkDiscriminant) .
        ( NetworkDiscriminantVal n
        , HasNetworkId n
        )
    => PipeliningStrategy (CardanoBlock StandardCrypto)
    -> Proxy n
    -> Tracer IO (BenchmarkLog n)
    -> Trace IO Text
    -- ^ For wallet tracing
    -> CardanoNodeConn
    -- ^ Socket path
    -> NetworkParameters
    -> NodeToClientVersionData
    -> Text
    -- ^ Benchmark name (used for naming resulting files)
    -> Bool
     -- ^ if to write to disk
    -> Percentage
    -- ^ Target sync progress
    -> IO SomeBenchmarkResults
bench_baseline_restoration
    pipeliningStrat proxy tr wlTr socket np vData benchName
        traceToDisk targetSync = do
            putStrLn $ "*** " ++ T.unpack benchName
            withRestoreEnvironment doRestore
  where
    withRestoreEnvironment action =
        withWalletLayerTracer benchName pipeliningStrat traceToDisk $
            \progressTrace -> withNetworkLayer
                networkTrace
                pipeliningStrat
                networkId np socket vData sTol $
                    \nw -> action progressTrace nw
      where
        networkId = networkIdVal proxy
        networkTrace = trMessageText wlTr
    doRestore
        :: Tracer IO (Maybe (Quantity "block" Word32))
        -> NetworkLayer IO (CardanoBlock StandardCrypto)
        -> IO SomeBenchmarkResults
    doRestore progressTrace nw = do
        wait <- newTVarIO Nothing
        chainPointT <- newTVarIO []
        synchronizer <- async
            $ chainSync nw nullTracer
            $ ChainFollower
            { readChainPoints  = readTVarIO chainPointT
            , rollForward = \blocks ntip -> do
                atomically $ writeTVar chainPointT
                    [chainPointFromBlockHeader ntip]
                let (ntxs, hss) = NE.unzip $
                        numberOfTransactionsInBlock <$> blocks
                    (heights, slots) = NE.unzip hss
                    tip = NE.last heights
                traceWith progressTrace $ Just tip
                seq (sum ntxs)
                    . atomically
                    . writeTVar wait
                    . Just
                    $ NE.last slots
            , rollBackward = pure
            }
        (_, restorationTime) <- bench "restoration" $
            reportProgress nw tr targetSync
                (atomically $ readTVar wait >>= maybe retry pure)
        saveBenchmarkPoints benchName restorationTime
        cancel synchronizer
        pure $ SomeBenchmarkResults
            BenchBaselineResults {benchName, restorationTime}

{- HLINT ignore bench_restoration "Use camelCase" -}
bench_restoration
    :: forall (n :: NetworkDiscriminant) (k :: Depth -> * -> *) s results.
        ( IsOurs s Address
        , IsOurs s RewardAccount
        , MaybeLight s
        , IsOwned s k
        , WalletKey k
        , NFData s
        , Show s
        , PersistAddressBook s
        , CompareDiscovery s
        , KnownAddresses s
        , PersistPrivateKey (k 'RootK)
        , NetworkDiscriminantVal n
        , HasNetworkId n
        , TxWitnessTagFor k
        , Buildable results
        , ToJSON results
        )
    => PipeliningStrategy (CardanoBlock StandardCrypto)
    -> Proxy n
    -> Tracer IO (BenchmarkLog n)
    -> Trace IO Text -- ^ For wallet tracing
    -> CardanoNodeConn  -- ^ Socket path
    -> NetworkParameters
    -> NodeToClientVersionData
    -> Text -- ^ Benchmark name (used for naming resulting files)
    -> [(WalletId, WalletName, s)]
    -> Bool -- ^ If @True@, will trace detailed progress to a .timelog file.
    -> Percentage -- ^ Target sync progress
    -> (Proxy n
        -> WalletLayer IO s k
        -> WalletId
        -> WalletName
        -> Text
        -> Time
        -> IO results)
    -> IO SomeBenchmarkResults
bench_restoration
    pipeliningStrat proxy tr wlTr socket np vData benchname wallets traceToDisk
        targetSync benchmarks = do
    putStrLn $ "*** " ++ T.unpack benchname
    let networkId = networkIdVal proxy
    let tl = newTransactionLayer @k networkId
    let gp = genesisParameters np
    withNetworkLayer (trMessageText wlTr) pipeliningStrat
        networkId np socket vData sTol $ \nw' -> do
            let convert = fromCardanoBlock gp
            let nw = convert <$> nw'
            let ti = neverFails "bench db shouldn't forecast into future"
                    $ timeInterpreter nw
            withBenchDBLayer ti wlTr
                $ \db -> withWalletLayerTracer
                    benchname pipeliningStrat traceToDisk
                $ \progressTrace -> do
                    let tracer =
                            trMessageText wlTr <>
                            contramap walletWorkerLogToBlockHeight progressTrace
                    let w = WalletLayer
                            tracer (emptyGenesis gp, np, sTol) nw tl db

                    forM_ wallets $ \(wid, wname, s) -> do
                        _ <- unsafeRunExceptT $ W.createWallet w wid wname s
                        void
                            $ forkIO
                            $ unsafeRunExceptT
                            $ W.restoreWallet @_ @s @k w wid

                    -- NOTE: This is now the time to restore /all/ wallets.
                    (_, restorationTime) <- bench "restoration" $ do
                        waitForWalletsSyncTo
                            targetSync
                            tr
                            proxy
                            w
                            (map fst' wallets)
                            gp
                            vData

                    let (wid0, wname0, _) = head wallets
                    results <-
                        benchmarks proxy w wid0 wname0 benchname restorationTime
                    saveBenchmarkPoints benchname results
                    forM_ wallets $ \(wid, _, _) ->
                        unsafeRunExceptT (W.deleteWallet w wid)
                    pure $ SomeBenchmarkResults results
  where
    fst' (x,_,_) = x

walletWorkerLogToBlockHeight
    :: WalletWorkerLog
    -> Maybe (Quantity "block" Word32)
walletWorkerLogToBlockHeight = \case
    MsgChainFollow (MsgChainSync (MsgChainRollForward bs _nodeTip)) ->
        Just $ blockHeight $ NE.last bs
    _ ->
        Nothing

saveBenchmarkPoints :: ToJSON a => Text -> a -> IO ()
saveBenchmarkPoints benchname = Aeson.encodeFile (T.unpack benchname <> ".json")

withWalletLayerTracer
    :: Show a
    => Text
    -> a
    -> Bool
    -> (Tracer IO (Maybe (Quantity "block" Word32)) -> IO r)
    -> IO r
withWalletLayerTracer benchname pipelining traceToDisk act = do
    let benchmarkFilename
            = T.unpack $ benchname
                <> "."
                <> T.replace " " "_" (T.pack $ show pipelining)
                <> ".timelog"
    t0 <- getCurrentTime
    if
        | traceToDisk ->
            withFile
                benchmarkFilename
                WriteMode
                $ \h -> do
                -- Use a custom tracer to output (time, blockHeight) to a file
                -- each time we apply blocks.
                let fileTr = Tracer $ \msg -> do
                        liftIO . B8.hPut h . T.encodeUtf8 . (<> "\n") $ msg
                        hFlush h
                act $ traceBlockHeadersProgressForPlotting t0 fileTr
        | otherwise -> act nullTracer

dummyAddress
    :: forall (n :: NetworkDiscriminant). NetworkDiscriminantVal n
    => Address
dummyAddress
    | networkDiscriminantVal @n == networkDiscriminantVal @'Mainnet =
        Address $ BS.pack $ 0 : replicate 56 0
    | otherwise =
        Address $ BS.pack $ 1 : replicate 56 0

-- | Hash the given text, and construct a mnemonic from it.
dummySeedFromName :: Text -> SomeMnemonic
dummySeedFromName = SomeMnemonic @24
    . entropyToMnemonic
    . unsafeMkEntropy @256
    . blake2b256
    . T.encodeUtf8

traceBlockHeadersProgressForPlotting
    :: UTCTime
    -> Tracer IO Text
    -> Tracer IO (Maybe (Quantity "block" Word32))
traceBlockHeadersProgressForPlotting t0  tr = Tracer $ \bs -> do
    let mtip = pretty . getQuantity <$> bs
    time <- pretty . (`diffUTCTime` t0) <$> getCurrentTime
    case mtip of
        Just tip -> traceWith tr $ time <> " " <> tip
        Nothing -> pure ()

withBenchDBLayer
    :: forall s k a.
        ( IsOwned s k
        , NFData s
        , Show s
        , PersistAddressBook s
        , IsOurs s RewardAccount
        , IsOurs s Address
        , PersistPrivateKey (k 'RootK)
        , WalletKey k
        )
    => TimeInterpreter IO
    -> Trace IO Text
    -> (DBLayer IO s k -> IO a)
    -> IO a
withBenchDBLayer ti tr action =
    withSystemTempFile "bench.db" $ \dbFile _ ->
        withDBLayer tr' migrationDefaultValues dbFile ti action
  where
    migrationDefaultValues = Sqlite.DefaultFieldValues
        { Sqlite.defaultActiveSlotCoefficient = 1
        , Sqlite.defaultDesiredNumberOfPool = 0
        , Sqlite.defaultMinimumUTxOValue = Coin 0
        , Sqlite.defaultHardforkEpoch = Nothing
        , Sqlite.defaultKeyDeposit = Coin 0
        }
    tr' = trMessageText tr

prepareNode
    :: forall n. (NetworkDiscriminantVal n, HasNetworkId n)
    => Tracer IO (BenchmarkLog n)
    -> Proxy n
    -> CardanoNodeConn
    -> NetworkParameters
    -> NodeToClientVersionData
    -> IO ()
prepareNode tr proxy socketPath np vData = do
    traceWith tr $ MsgSyncStart proxy
    let networkId = networkIdVal proxy
    sl <- withNetworkLayer nullTracer
            tunedForMainnetPipeliningStrategy
            networkId np socketPath vData sTol $ \nw' -> do
        let gp = genesisParameters np
        let convert = fromCardanoBlock gp
        let nw = convert <$> nw'
        waitForNodeSync tr nw
    traceWith tr $ MsgSyncCompleted proxy sl

-- | Regularly poll the wallets to monitor syncing progress. Block until all
-- wallets reach the given percentage.
waitForWalletsSyncTo
    :: forall s k n. (NetworkDiscriminantVal n)
    => Percentage
    -> Tracer IO (BenchmarkLog n)
    -> Proxy n
    -> WalletLayer IO s k
    -> [WalletId]
    -> GenesisParameters
    -> NodeToClientVersionData
    -> IO ()
waitForWalletsSyncTo targetSync tr proxy walletLayer wids gp vData = do
    posixNow <- utcTimeToPOSIXSeconds <$> getCurrentTime
    progress <- forM wids $ \wid -> do
        w <- fmap fst' <$> unsafeRunExceptT $ W.readWallet walletLayer wid
        syncProgress nl (slotNo $ currentTip w)
    traceWith tr $ MsgRestorationTick posixNow progress
    threadDelay 1000000

    if all (> Syncing (Quantity targetSync)) progress
    then return ()
    else waitForWalletsSyncTo targetSync tr proxy walletLayer wids gp vData
  where
    WalletLayer _ _ nl _ _ = walletLayer
    fst' (x,_,_) = x

reportProgress
    :: NetworkLayer IO block
    -> Tracer IO (BenchmarkLog n)
    -> Percentage
    -> IO SlotNo
    -> IO ()
reportProgress nw tr targetSync readSlot =  do
    posixNow <- utcTimeToPOSIXSeconds <$> getCurrentTime
    progress <- readSlot >>= syncProgress nw
    traceWith tr $ MsgRestorationTick posixNow [progress]
    threadDelay 1000000
    if progress > Syncing (Quantity targetSync)
        then return ()
        else reportProgress nw tr targetSync readSlot

-- | Poll the network tip until it reaches the slot corresponding to the current
-- time.
waitForNodeSync
    :: forall n. (NetworkDiscriminantVal n)
    => Tracer IO (BenchmarkLog n)
    -> NetworkLayer IO Block
    -> IO SlotNo
waitForNodeSync tr nw = loop 960 -- allow 240 minutes for first tip
  where
    loop :: Int -> IO SlotNo
    loop retries = do
        nodeTip <- currentNodeTip nw
        if slotNo nodeTip /= 0 then do
            prog <- syncProgress nw $ slotNo nodeTip
            traceWith tr $ MsgNodeTipTick nodeTip prog
            if prog == Ready
                then pure (slotNo nodeTip)
                else do
                    -- 2 seconds poll interval
                    threadDelay 2000000
                    loop retries
        else
            if retries > 0 then do
                 let delay = 15000000
                 traceWith tr $ MsgRetryShortly delay
                 threadDelay delay
                 loop (retries - 1)
            else throwString "Gave up in waitForNodeSync, waiting a tip"

data BenchmarkLog (n :: NetworkDiscriminant)
    = MsgNodeTipTick BlockHeader SyncProgress
    | MsgRestorationTick POSIXTime [SyncProgress]
    | MsgSyncStart (Proxy n)
    | MsgSyncCompleted (Proxy n) SlotNo
    | MsgRetryShortly Int
    deriving (Show, Eq)

instance HasPrivacyAnnotation (BenchmarkLog n)
instance HasSeverityAnnotation (BenchmarkLog n) where
    getSeverityAnnotation = \case
        MsgNodeTipTick{} -> Info
        MsgRestorationTick{} -> Info
        MsgSyncStart{} -> Info
        MsgSyncCompleted{} -> Info
        MsgRetryShortly{} -> Warning

instance NetworkDiscriminantVal n => ToText (BenchmarkLog n) where
    toText = \case
        MsgNodeTipTick tip progress ->
            "Initial node synchronization: "
                +| progress |+ " "
                +| tip ||+ ""
        MsgRestorationTick _posixTime progressList ->
            "Restoring: "
                +| progressList |+ ""
        MsgSyncStart _ ->
            "Syncing "
                +| networkDiscriminantVal @n |+ " node... "
        MsgSyncCompleted _ tip ->
            "Completed sync of "
                +| networkDiscriminantVal @n |+ " up to " +|| tip ||+ ""
        MsgRetryShortly delay ->
            "Fetching tip failed, retrying in "
                +|| (delay `div` 1000) ||+ "ms"


-- | Format a type-level per-myriad number as percent
--
-- >>> showPercentFromPermyriad (Proxy @1)
-- "0.01"
--
-- >>> showPercentFromPermyriad (Proxy @0)
-- "0"
--
-- Unfortunately we have:
--
-- >>> showPercentFromPermyriad (Proxy @10)
-- "0.10"
--
-- rather than "0.1", but we'll have to live with it.
showPercentFromPermyriad :: forall (p :: Nat) . KnownNat p => Proxy p -> Text
showPercentFromPermyriad =
    T.pack . display . (/100) . toRational . natVal
  where
    -- I cannot find a haskell way to format a rational with as few decimals as
    -- possible, so this will have to do:
    display :: Rational -> String
    display 0 = "0"
    display x = showFFloat @Double (Just 2) (fromRat x) ""

sTol :: SyncTolerance
sTol = mkSyncTolerance 3600
