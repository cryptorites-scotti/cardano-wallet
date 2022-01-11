{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

-- |
-- Copyright: © 2021 IOHK
-- License: Apache-2.0
--
-- Old-style storage for 'Checkpoints' in the database.
--
-- FIXME LATER during ADP-1043:
-- Swap this module out by "Cardano.Wallet.DB.Sqlite.Checkpoints"

module Cardano.Wallet.DB.Sqlite.CheckpointsOld
    ( mkStoreWalletsCheckpoints
    , PersistAddressBook (..)
    , blockHeaderFromEntity
    )
    where

import Prelude

import Cardano.Address.Derivation
    ( XPub )
import Cardano.Address.Script
    ( Cosigner (..), ScriptTemplate (..) )
import Cardano.DB.Sqlite
    ( dbChunked )
import Cardano.Wallet.DB
    ( ErrBadFormat (..) )
import Cardano.Wallet.DB.Checkpoints
    ( Checkpoints (..)
    , DeltaCheckpoints (..)
    , DeltaMap (..)
    , getPoint
    , loadCheckpoints
    )
import Cardano.Wallet.DB.Sqlite.AddressBook
    ( AddressBookIso (..)
    , Discoveries (..)
    , Prologue (..)
    , SeqAddressList (..)
    )
import Cardano.Wallet.DB.Sqlite.TH
    ( Checkpoint (..)
    , CosignerKey (..)
    , EntityField (..)
    , Key (..)
    , RndState (..)
    , RndStateAddress (..)
    , RndStatePendingAddress (..)
    , SeqState (..)
    , SeqStateAddress (..)
    , SeqStatePendingIx (..)
    , SharedState (..)
    , UTxO (..)
    , UTxOToken (..)
    , Wallet (..)
    )
import Cardano.Wallet.DB.Sqlite.Types
    ( BlockId (..)
    , HDPassphrase (..)
    , TxId (..)
    , fromMaybeHash
    , hashOfNoParent
    , toMaybeHash
    )
import Cardano.Wallet.Primitive.AddressDerivation
    ( Depth (..)
    , MkKeyFingerprint (..)
    , PaymentAddress (..)
    , PersistPublicKey (..)
    , Role (..)
    , SoftDerivation (..)
    , WalletKey (..)
    )
import Cardano.Wallet.Primitive.AddressDerivation.SharedKey
    ( SharedKey (..) )
import Cardano.Wallet.Primitive.AddressDiscovery
    ( GetPurpose )
import Cardano.Wallet.Primitive.AddressDiscovery.Shared
    ( CredentialType (..) )
import Cardano.Wallet.Primitive.Types.TokenBundle
    ( TokenBundle )
import Cardano.Wallet.Primitive.Types.TokenMap
    ( AssetId (..) )
import Cardano.Wallet.Util
    ( invariant )
import Control.Applicative
    ( Alternative )
import Control.Monad
    ( MonadPlus, forM, forM_, unless, void, when )
import Control.Monad.Class.MonadSTM
    ( MonadSTM (..) )
import Control.Monad.IO.Class
    ( MonadIO (..) )
import Control.Monad.Trans.Class
    ( lift )
import Control.Monad.Trans.Except
    ( ExceptT (..), runExceptT )
import Control.Monad.Trans.Maybe
    ( MaybeT (..) )
import Control.Monad.Trans.Reader
    ( ReaderT (..) )
import Data.Bifunctor
    ( bimap, second )
import Data.DBVar
    ( Store (..) )
import Data.Functor
    ( (<&>) )
import Data.Generics.Internal.VL
    ( withIso )
import Data.Generics.Internal.VL.Lens
    ( view, (^.) )
import Data.Map.Strict
    ( Map )
import Data.Maybe
    ( fromJust, isJust, isNothing )
import Data.Proxy
    ( Proxy (..) )
import Data.Quantity
    ( Quantity (..) )
import Data.Type.Equality
    ( type (==) )
import Data.Typeable
    ( Typeable )
import Database.Persist.Sql
    ( Entity (..)
    , SelectOpt (..)
    , SqlBackend
    , deleteWhere
    , insertMany_
    , insert_
    , repsert
    , selectFirst
    , selectList
    , (!=.)
    , (/<-.)
    , (==.)
    , (>.)
    )
import Database.Persist.Sqlite
    ( SqlPersistT )
import UnliftIO.Exception
    ( toException )

import qualified Cardano.Wallet.Primitive.AddressDerivation as W
import qualified Cardano.Wallet.Primitive.AddressDiscovery.Random as Rnd
import qualified Cardano.Wallet.Primitive.AddressDiscovery.Sequential as Seq
import qualified Cardano.Wallet.Primitive.AddressDiscovery.Shared as Shared
import qualified Cardano.Wallet.Primitive.Model as W
import qualified Cardano.Wallet.Primitive.Types as W
import qualified Cardano.Wallet.Primitive.Types.Address as W
import qualified Cardano.Wallet.Primitive.Types.Coin as W
import qualified Cardano.Wallet.Primitive.Types.TokenBundle as TokenBundle
import qualified Cardano.Wallet.Primitive.Types.Tx as W
import qualified Cardano.Wallet.Primitive.Types.UTxO as W
import qualified Control.Concurrent.STM.TBQueue as STM
import qualified Control.Concurrent.STM.TMVar as STM
import qualified Control.Concurrent.STM.TQueue as STM
import qualified Control.Concurrent.STM.TVar as STM
import qualified Control.Monad.STM as STM
import qualified Data.Map.Merge.Strict as Map
import qualified Data.Map.Strict as Map

{-------------------------------------------------------------------------------
    Checkpoints Store
-------------------------------------------------------------------------------}
-- | Store for 'Checkpoints' of multiple different wallets.
mkStoreWalletsCheckpoints
    :: forall s key. (PersistAddressBook s, key ~ W.WalletId)
    => Store (SqlPersistT IO)
        (DeltaMap key (DeltaCheckpoints (W.Wallet s)))
mkStoreWalletsCheckpoints = Store{loadS=load,writeS=write,updateS=update}
  where
    write = error "mkStoreWalletsCheckpoints: not implemented"

    update _ (Insert wid a) =
        writeS (mkStoreCheckpoints wid) a
    update _ (Delete wid) = do
        -- FIXME LATER during ADP-1043:
        --  Deleting an entry in the Checkpoint table
        --  will trigger a delete cascade. We want this cascade
        --  to be explicit in our code.
        deleteWhere [CheckpointWalletId ==. wid]
    update _ (Adjust wid da) =
        updateS (mkStoreCheckpoints wid) undefined da
        -- FIXME LATER during ADP-1043:
        --   Remove 'undefined'.
        --   Probably needs a change to 'Data.DBVar.updateS'
        --   to take a 'Maybe a' as parameter instead of an 'a'.

    load = do
        wids <- fmap (view #walId . entityVal) <$> selectAll
        runExceptT $ do
            xs <- forM wids $ ExceptT . loadS . mkStoreCheckpoints
            pure $ Map.fromList (zip wids xs)
      where
        selectAll :: SqlPersistT IO [Entity Wallet]
        selectAll = selectList [] []

-- | Store for 'Checkpoints' of a single wallet.
mkStoreCheckpoints
    :: forall s. PersistAddressBook s
    => W.WalletId
    -> Store (SqlPersistT IO) (DeltaCheckpoints (W.Wallet s))
mkStoreCheckpoints wid =
    Store{ loadS = load, writeS = write, updateS = \_ -> update }
  where
    load = bimap toException loadCheckpoints <$> selectAllCheckpoints wid

    write cps = forM_ (Map.toList $ checkpoints cps) $ \(pt,cp) ->
            update (PutCheckpoint pt cp)

    update (PutCheckpoint _ state) =
        insertCheckpoint wid state
    update (RollbackTo (W.At slot)) =
        deleteWhere [ CheckpointWalletId ==. wid, CheckpointSlot >. slot ]
    update (RollbackTo W.Origin) =
        deleteWhere
            [ CheckpointWalletId ==. wid
            , CheckpointParentHash !=. BlockId hashOfNoParent
            ]
    update (RestrictTo points) = do
        let pseudoSlot W.Origin    = W.SlotNo 0
            pseudoSlot (W.At slot) = slot
        let slots = map pseudoSlot points
        deleteWhere [ CheckpointWalletId ==. wid, CheckpointSlot /<-. slots ]

        -- We may have to delete the checkpoint at SlotNo 0 that is not genesis.
        let slot0 = W.At $ W.SlotNo 0
        unless (slot0 `elem` points) $
            deleteWhere
                [ CheckpointWalletId ==. wid
                , CheckpointSlot ==. W.SlotNo 0
                , CheckpointParentHash !=. BlockId hashOfNoParent
                ]

{-------------------------------------------------------------------------------
    Database operations
-------------------------------------------------------------------------------}
selectAllCheckpoints
    :: forall s. PersistAddressBook s
    => W.WalletId
    -> SqlPersistT IO (Either ErrBadFormat [(W.Slot, W.Wallet s)])
selectAllCheckpoints wid = do
    cps <- fmap entityVal <$> selectList
        [ CheckpointWalletId ==. wid ]
        [ Desc CheckpointSlot ]
    -- FIXME LATER during ADP-1043: Presence of these tables?
    mprologue <- loadPrologue wid
    case mprologue of
        Nothing -> pure $ Left ErrBadFormatAddressState
        Just prologue -> fmap Right $
            forM cps $ \cp -> do
                utxo <- selectUTxO cp
                discoveries <- loadDiscoveries wid (checkpointSlot cp)
                let st = withIso addressIso $ \_ from ->
                        from (prologue, discoveries)
                    c = checkpointFromEntity @s cp utxo st
                pure (getPoint c, c)

selectUTxO
    :: Checkpoint
    -> SqlPersistT IO ([UTxO], [UTxOToken])
selectUTxO cp = do
    coins <- fmap entityVal <$>
        selectList
            [ UtxoWalletId ==. checkpointWalletId cp
            , UtxoSlot ==. checkpointSlot cp
            ] []
    tokens <- fmap entityVal <$>
        selectList
            [ UtxoTokenWalletId ==. checkpointWalletId cp
            , UtxoTokenSlot ==. checkpointSlot cp
            ] []
    return (coins, tokens)

insertCheckpoint
    :: forall s. (PersistAddressBook s)
    => W.WalletId
    -> W.Wallet s
    -> SqlPersistT IO ()
insertCheckpoint wid wallet = do
    let (cp, utxo, utxoTokens) = mkCheckpointEntity wid wallet
    let sl = (W.currentTip wallet) ^. #slotNo
    deleteWhere [CheckpointWalletId ==. wid, CheckpointSlot ==. sl]
    insert_ cp
    dbChunked insertMany_ utxo
    dbChunked insertMany_ utxoTokens
    withIso addressIso $ \to _ -> do
        let (prologue, discoveries) = to $ W.getState wallet
        insertPrologue wid prologue
        insertDiscoveries wid sl discoveries

{-------------------------------------------------------------------------------
    Database type conversions
-------------------------------------------------------------------------------}
blockHeaderFromEntity :: Checkpoint -> W.BlockHeader
blockHeaderFromEntity cp = W.BlockHeader
    { slotNo = checkpointSlot cp
    , blockHeight = Quantity (checkpointBlockHeight cp)
    , headerHash = getBlockId (checkpointHeaderHash cp)
    , parentHeaderHash = toMaybeHash (checkpointParentHash cp)
    }

mkCheckpointEntity
    :: W.WalletId
    -> W.Wallet s
    -> (Checkpoint, [UTxO], [UTxOToken])
mkCheckpointEntity wid wal =
    (cp, utxo, utxoTokens)
  where
    header = W.currentTip wal
    sl = header ^. #slotNo
    (Quantity bh) = header ^. #blockHeight
    cp = Checkpoint
        { checkpointWalletId = wid
        , checkpointSlot = sl
        , checkpointParentHash = fromMaybeHash (header ^. #parentHeaderHash)
        , checkpointHeaderHash = BlockId (header ^. #headerHash)
        , checkpointBlockHeight = bh
        }
    utxo =
        [ UTxO wid sl (TxId input) ix addr (TokenBundle.getCoin tokens)
        | (W.TxIn input ix, W.TxOut addr tokens) <- utxoMap
        ]
    utxoTokens =
        [ UTxOToken wid sl (TxId input) ix policy token quantity
        | (W.TxIn input ix, W.TxOut {tokens}) <- utxoMap
        , let tokenList = snd (TokenBundle.toFlatList tokens)
        , (AssetId policy token, quantity) <- tokenList
        ]
    utxoMap = Map.assocs (W.unUTxO (W.utxo wal))

-- note: TxIn records must already be sorted by order
-- and TxOut records must already by sorted by index.
checkpointFromEntity
    :: Checkpoint
    -> ([UTxO], [UTxOToken])
    -> s
    -> W.Wallet s
checkpointFromEntity cp (coins, tokens) =
    W.unsafeInitWallet utxo header
  where
    header = blockHeaderFromEntity cp

    utxo = W.UTxO $ Map.merge
        (Map.mapMissing (const mkFromCoin)) -- No assets, only coins
        (Map.dropMissing) -- Only assets, impossible.
        (Map.zipWithMatched (const mkFromBoth)) -- Both assets and coins
        (Map.fromList
            [ (W.TxIn input ix, (addr, coin))
            | (UTxO _ _ (TxId input) ix addr coin) <- coins
            ])
        (Map.fromListWith TokenBundle.add
            [ (W.TxIn input ix, mkTokenEntry token)
            | (token@(UTxOToken _ _ (TxId input) ix _ _ _)) <- tokens
            ])

    mkFromCoin :: (W.Address, W.Coin) -> W.TxOut
    mkFromCoin (addr, coin) =
        W.TxOut addr (TokenBundle.fromCoin coin)

    mkFromBoth :: (W.Address, W.Coin) -> TokenBundle -> W.TxOut
    mkFromBoth (addr, coin) bundle =
        W.TxOut addr (TokenBundle.add (TokenBundle.fromCoin coin) bundle)

    mkTokenEntry token = TokenBundle.fromFlatList (W.Coin 0)
        [ ( AssetId (utxoTokenPolicyId token) (utxoTokenName token)
          , utxoTokenQuantity token
          )
        ]

{-------------------------------------------------------------------------------
    AddressBook storage
-------------------------------------------------------------------------------}
-- | Functions for saving / loading the wallet's address book to / from SQLite
class AddressBookIso s => PersistAddressBook s where
    insertPrologue
        :: W.WalletId -> Prologue s -> SqlPersistT IO ()
    insertDiscoveries
        :: W.WalletId -> W.SlotNo -> Discoveries s -> SqlPersistT IO ()

    loadPrologue
        :: W.WalletId -> SqlPersistT IO (Maybe (Prologue s))
    loadDiscoveries
        :: W.WalletId -> W.SlotNo -> SqlPersistT IO (Discoveries s)

{-------------------------------------------------------------------------------
    Sequential address book storage
-------------------------------------------------------------------------------}
-- piggy-back on SeqState existing instance, to simulate the same behavior.
instance PersistAddressBook (Seq.SeqState n k)
    => PersistAddressBook (Seq.SeqAnyState n k p)
  where
    insertPrologue wid (PS s) = insertPrologue wid s
    insertDiscoveries wid sl (DS s) = insertDiscoveries wid sl s
    loadPrologue wid = fmap PS <$> loadPrologue wid
    loadDiscoveries wid sl = DS <$> loadDiscoveries wid sl

instance
    ( Eq (key 'AccountK XPub)
    , PersistPublicKey (key 'AccountK)
    , PersistPublicKey (key 'AddressK)
    , MkKeyFingerprint key (Proxy n, key 'AddressK XPub)
    , GetPurpose key
    , PaymentAddress n key
    , SoftDerivation key
    , (key == SharedKey) ~ 'False
    ) => PersistAddressBook (Seq.SeqState n key) where

    insertPrologue wid (SeqPrologue st) = do
        let (intPool, extPool) =
                (Seq.internalPool st, Seq.externalPool st)
        let (Seq.ParentContextUtxo accXPubInternal) = Seq.context intPool
        let (Seq.ParentContextUtxo accXPubExternal) = Seq.context extPool
        let (accountXPub, _) = invariant
                "Internal & External pool use different account public keys!"
                ( accXPubExternal, accXPubInternal )
                (uncurry (==))
        let eGap = Seq.gap extPool
        let iGap = Seq.gap intPool
        repsert (SeqStateKey wid) $ SeqState
            { seqStateWalletId = wid
            , seqStateExternalGap = eGap
            , seqStateInternalGap = iGap
            , seqStateAccountXPub = serializeXPub accountXPub
            , seqStateRewardXPub = serializeXPub (Seq.rewardAccountKey st)
            , seqStateDerivationPrefix = Seq.derivationPrefix st
            }
        deleteWhere [SeqStatePendingWalletId ==. wid]
        dbChunked
            insertMany_
            (mkSeqStatePendingIxs wid $ Seq.pendingChangeIxs st)

    insertDiscoveries wid sl
        (SeqDiscoveries (SeqAddressList ints) (SeqAddressList exts))
      = do
        void $ dbChunked insertMany_
            [ SeqStateAddress wid sl addr ix UtxoInternal state
            | (ix, (addr, state)) <- zip [0..] ints
            ]
        void $ dbChunked insertMany_
            [ SeqStateAddress wid sl addr ix UtxoExternal state
            | (ix, (addr, state)) <- zip [0..] exts
            ]

    loadPrologue wid = runMaybeT $ do
        st <- MaybeT $ selectFirst [SeqStateWalletId ==. wid] []
        let SeqState _ eGap iGap accountBytes rewardBytes prefix = entityVal st
        let accountXPub = unsafeDeserializeXPub accountBytes
        let rewardXPub = unsafeDeserializeXPub rewardBytes
        let intPool = Seq.mkAddressPool @n (Seq.ParentContextUtxo accountXPub) iGap []
        let extPool = Seq.mkAddressPool @n (Seq.ParentContextUtxo accountXPub) eGap []
        pendingChangeIxs <- lift $ selectSeqStatePendingIxs wid
        pure $ SeqPrologue $
            Seq.SeqState intPool extPool pendingChangeIxs rewardXPub prefix

    loadDiscoveries wid sl =
        SeqDiscoveries
            <$> selectSeqAddressList wid sl
            <*> selectSeqAddressList wid sl

mkSeqStatePendingIxs :: W.WalletId -> Seq.PendingIxs -> [SeqStatePendingIx]
mkSeqStatePendingIxs wid =
    fmap (SeqStatePendingIx wid . W.getIndex) . Seq.pendingIxsToList

selectSeqStatePendingIxs :: W.WalletId -> SqlPersistT IO Seq.PendingIxs
selectSeqStatePendingIxs wid =
    Seq.pendingIxsFromList . fromRes <$> selectList
        [SeqStatePendingWalletId ==. wid]
        [Desc SeqStatePendingIxIndex]
  where
    fromRes = fmap (W.Index . seqStatePendingIxIndex . entityVal)

selectSeqAddressList
    :: forall c. Typeable c
    => W.WalletId -> W.SlotNo -> SqlPersistT IO (SeqAddressList c)
selectSeqAddressList wid sl = do
    SeqAddressList . map (toPair . entityVal) <$> selectList
        [ SeqStateAddressWalletId ==. wid
        , SeqStateAddressSlot ==. sl
        , SeqStateAddressRole ==. Seq.role @c
        ] [Asc SeqStateAddressIndex]
  where
    toPair x = (seqStateAddressAddress x, seqStateAddressStatus x)

{-------------------------------------------------------------------------------
    Shared key address book storage
-------------------------------------------------------------------------------}
instance
    ( PersistPublicKey (key 'AccountK)
    , Shared.SupportsDiscovery n key
    , WalletKey key
    , key ~ SharedKey
    ) => PersistAddressBook (Shared.SharedState n key) where

    insertPrologue wid (SharedPrologue st) = do
        let Shared.SharedState prefix accXPub pTemplate dTemplateM gap _ = st
        insertSharedState prefix accXPub gap pTemplate dTemplateM
        insertCosigner (cosigners pTemplate) Payment
        when (isJust dTemplateM) $
            insertCosigner (fromJust $ cosigners <$> dTemplateM) Delegation
      where
         insertSharedState prefix accXPub gap pTemplate dTemplateM = do
             deleteWhere [SharedStateWalletId ==. wid]
             insert_ $ SharedState
                 { sharedStateWalletId = wid
                 , sharedStateAccountXPub = serializeXPub accXPub
                 , sharedStateScriptGap = gap
                 , sharedStatePaymentScript = template pTemplate
                 , sharedStateDelegationScript = template <$> dTemplateM
                 , sharedStateDerivationPrefix = prefix
                 }

         insertCosigner cs cred = do
             deleteWhere [CosignerKeyWalletId ==. wid, CosignerKeyCredential ==. cred]
             dbChunked insertMany_
                 [ CosignerKey wid cred (serializeXPub @(key 'AccountK) $ liftRawKey xpub) c
                 | ((Cosigner c), xpub) <- Map.assocs cs
                 ]

    insertDiscoveries wid sl (SharedDiscoveries addrs) = do
        dbChunked insertMany_
            [ SeqStateAddress wid sl addr ix UtxoExternal status
            | (ix, addr, status) <- map convert $ Map.toList addrs
            ]
      where
        convert (addr,(ix,status)) =
            (fromIntegral $ fromEnum ix, Shared.liftPaymentAddress @n addr, status)

    loadPrologue wid = runMaybeT $ do
        st <- MaybeT $ selectFirst [SharedStateWalletId ==. wid] []
        let SharedState _ accountBytes gap pScript dScriptM prefix = entityVal st
        let accXPub = unsafeDeserializeXPub accountBytes
        pCosigners <- lift $ selectCosigners @key wid Payment
        dCosigners <- lift $ selectCosigners @key wid Delegation

        let prepareKeys = map (second getRawKey)
            pTemplate = ScriptTemplate (Map.fromList $ prepareKeys pCosigners) pScript
            dTemplateM = ScriptTemplate (Map.fromList $ prepareKeys dCosigners) <$> dScriptM
            mkSharedState = Shared.SharedState prefix accXPub pTemplate dTemplateM gap
        prologue <- lift $ multisigPoolAbsent wid <&> \case
            True ->  mkSharedState Shared.Pending
            False -> mkSharedState $ Shared.Active
                $ Shared.newSharedAddressPool @n gap pTemplate dTemplateM
        pure $ SharedPrologue prologue

    loadDiscoveries wid sl = do
        addrs <- map entityVal <$> selectList
            [ SeqStateAddressWalletId ==. wid
            , SeqStateAddressSlot ==. sl
            , SeqStateAddressRole ==. UtxoExternal
            ] [Asc SeqStateAddressIndex]
        pure $ SharedDiscoveries $ Map.fromList 
            [ (fingerprint, (toEnum $ fromIntegral ix, status))
            | SeqStateAddress _ _ addr ix _ status <- addrs
            , Right fingerprint <- [paymentKeyFingerprint addr]
            ]

selectCosigners
    :: forall k. PersistPublicKey (k 'AccountK)
    => W.WalletId
    -> CredentialType
    -> SqlPersistT IO [(Cosigner, k 'AccountK XPub)]
selectCosigners wid cred = do
    fmap (cosignerFromEntity . entityVal) <$> selectList
        [ CosignerKeyWalletId ==. wid
        , CosignerKeyCredential ==. cred
        ] []
 where
   cosignerFromEntity (CosignerKey _ _ key c) =
       (Cosigner c, unsafeDeserializeXPub key)

-- | Check whether we have ever stored checkpoints for a multi-signature pool
multisigPoolAbsent :: W.WalletId -> SqlPersistT IO Bool
multisigPoolAbsent wid =
    isNothing <$> selectFirst
        [ SeqStateAddressWalletId ==. wid
        , SeqStateAddressRole ==. UtxoExternal
        ] []

{-------------------------------------------------------------------------------
    HD Random address book storage
-------------------------------------------------------------------------------}
-- piggy-back on RndState existing instance, to simulate the same behavior.
instance PersistAddressBook (Rnd.RndAnyState n p)
  where
    insertPrologue wid (PR s) = insertPrologue wid s
    insertDiscoveries wid sl (DR s) = insertDiscoveries wid sl s
    loadPrologue wid = fmap PR <$> loadPrologue wid
    loadDiscoveries wid sl = DR <$> loadDiscoveries wid sl

-- | Persisting 'RndState' requires that the wallet root key has already been
-- added to the database with 'putPrivateKey'. Unlike sequential AD, random
-- address discovery requires a root key to recognize addresses.
instance PersistAddressBook (Rnd.RndState n) where
    insertPrologue wid (RndPrologue st) = do
        let ix  = W.getIndex (st ^. #accountIndex)
        let gen = st ^. #gen
        let pwd = st ^. #hdPassphrase
        repsert (RndStateKey wid) (RndState wid ix gen (HDPassphrase pwd))
        insertRndStatePending wid (st ^. #pendingAddresses)

    insertDiscoveries wid sl (RndDiscoveries addresses) = do
        dbChunked insertMany_
            [ RndStateAddress wid sl accIx addrIx addr st
            | ((W.Index accIx, W.Index addrIx), (addr, st))
                <- Map.assocs addresses
            ]

    loadPrologue wid = runMaybeT $ do
        st <- MaybeT $ selectFirst
            [ RndStateWalletId ==. wid
            ] []
        let (RndState _ ix gen (HDPassphrase pwd)) = entityVal st
        pendingAddresses <- lift $ selectRndStatePending wid
        pure $ RndPrologue $ Rnd.RndState
            { hdPassphrase = pwd
            , accountIndex = W.Index ix
            , discoveredAddresses = Map.empty
            , pendingAddresses = pendingAddresses
            , gen = gen
            }

    loadDiscoveries wid sl = do
        addrs <- map (assocFromEntity . entityVal) <$> selectList
            [ RndStateAddressWalletId ==. wid
            , RndStateAddressSlot ==. sl
            ] []
        pure $ RndDiscoveries $ Map.fromList addrs
      where
        assocFromEntity (RndStateAddress _ _ accIx addrIx addr st) =
            ((W.Index accIx, W.Index addrIx), (addr, st))

insertRndStatePending
    :: W.WalletId
    -> Map Rnd.DerivationPath W.Address
    -> SqlPersistT IO ()
insertRndStatePending wid addresses = do
    deleteWhere [RndStatePendingAddressWalletId ==. wid]
    dbChunked insertMany_
        [ RndStatePendingAddress wid accIx addrIx addr
        | ((W.Index accIx, W.Index addrIx), addr) <- Map.assocs addresses
        ]

selectRndStatePending
    :: W.WalletId
    -> SqlPersistT IO (Map Rnd.DerivationPath W.Address)
selectRndStatePending wid = do
    addrs <- fmap entityVal <$> selectList
        [ RndStatePendingAddressWalletId ==. wid
        ] []
    pure $ Map.fromList $ map assocFromEntity addrs
  where
    assocFromEntity (RndStatePendingAddress _ accIx addrIx addr) =
        ((W.Index accIx, W.Index addrIx), addr)

{-------------------------------------------------------------------------------
                     Provide ReaderT instance for MonadSTM
-------------------------------------------------------------------------------}

instance MonadSTM (ReaderT SqlBackend IO) where
    type STM (ReaderT SqlBackend IO) = WrapSTM
    atomically = liftIO . STM.atomically . unWrapSTM

    type TVar (ReaderT SqlBackend IO) = TVar IO
    type TMVar (ReaderT SqlBackend IO) = TMVar IO
    type TBQueue (ReaderT SqlBackend IO) = TBQueue IO
    type TQueue (ReaderT SqlBackend IO) = TQueue IO

    newTVar        =       WrapSTM . STM.newTVar
    readTVar       =       WrapSTM . STM.readTVar
    writeTVar      = \v -> WrapSTM . STM.writeTVar v
    retry          = WrapSTM STM.retry
    orElse         = \(WrapSTM a) (WrapSTM b) -> WrapSTM (STM.orElse a b)
    modifyTVar     = \v -> WrapSTM . STM.modifyTVar v
    modifyTVar'    = \v -> WrapSTM . STM.modifyTVar' v
    stateTVar      = \v -> WrapSTM . STM.stateTVar v
    swapTVar       = \v -> WrapSTM . STM.swapTVar v
    check          =       WrapSTM . STM.check
    newTMVar       =       WrapSTM . STM.newTMVar
    newEmptyTMVar  =       WrapSTM STM.newEmptyTMVar
    takeTMVar      =       WrapSTM . STM.takeTMVar
    tryTakeTMVar   =       WrapSTM . STM.tryTakeTMVar
    putTMVar       = \v -> WrapSTM . STM.putTMVar v
    tryPutTMVar    = \v -> WrapSTM . STM.tryPutTMVar v
    readTMVar      =       WrapSTM . STM.readTMVar
    tryReadTMVar   =       WrapSTM . STM.tryReadTMVar
    swapTMVar      = \v -> WrapSTM . STM.swapTMVar v
    isEmptyTMVar   =       WrapSTM . STM.isEmptyTMVar
    newTQueue      =       WrapSTM STM.newTQueue
    readTQueue     =       WrapSTM . STM.readTQueue
    tryReadTQueue  =       WrapSTM . STM.tryReadTQueue
    peekTQueue     =       WrapSTM . STM.peekTQueue
    tryPeekTQueue  =       WrapSTM . STM.tryPeekTQueue
    flushTBQueue   =       WrapSTM . STM.flushTBQueue
    writeTQueue    = \q -> WrapSTM . STM.writeTQueue q
    isEmptyTQueue  =       WrapSTM . STM.isEmptyTQueue
    newTBQueue     =       WrapSTM . STM.newTBQueue
    readTBQueue    =       WrapSTM . STM.readTBQueue
    tryReadTBQueue =       WrapSTM . STM.tryReadTBQueue
    peekTBQueue    =       WrapSTM . STM.peekTBQueue
    tryPeekTBQueue =       WrapSTM . STM.tryPeekTBQueue
    writeTBQueue   = \q -> WrapSTM . STM.writeTBQueue q
    lengthTBQueue  =       WrapSTM . STM.lengthTBQueue
    isEmptyTBQueue =       WrapSTM . STM.isEmptyTBQueue
    isFullTBQueue  =       WrapSTM . STM.isFullTBQueue

    newTVarIO       = liftIO . STM.newTVarIO
    readTVarIO      = liftIO . STM.readTVarIO
    newTMVarIO      = liftIO . STM.newTMVarIO
    newEmptyTMVarIO = liftIO STM.newEmptyTMVarIO
    newTQueueIO     = liftIO STM.newTQueueIO
    newTBQueueIO    = liftIO . STM.newTBQueueIO

-- | MonadSTM is an injective typeclass, so we need a unique newtype to target.
newtype WrapSTM a = WrapSTM { unWrapSTM :: STM.STM a }
    deriving (Applicative, Functor, Monad)

deriving instance MonadPlus WrapSTM
deriving instance Alternative WrapSTM
