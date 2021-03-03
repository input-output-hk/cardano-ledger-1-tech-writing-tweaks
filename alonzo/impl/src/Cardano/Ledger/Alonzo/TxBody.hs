{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}

module Cardano.Ledger.Alonzo.TxBody
  ( TxOut (TxOut, TxOutCompact),
    TxBody
      ( TxBody,
        inputs,
        txinputs_fee,
        outputs,
        txcerts,
        txwdrls,
        txfee,
        txvldt,
        txUpdates,
        txADhash,
        mint,
        sdHash,
        scriptHash
      ),
    AlonzoBody,
    EraIndependentWitnessPPData,
    WitnessPPDataHash,
    ppTxBody,
    ppTxOut,
  )
where

import Cardano.Binary (FromCBOR (..), ToCBOR (..))
import Cardano.Ledger.Alonzo.Data (AuxiliaryDataHash, DataHash)
import Cardano.Ledger.Compactible
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.Crypto as CC
import Cardano.Ledger.Era (Crypto, Era)
import Cardano.Ledger.Mary.Value (Value (..), ppValue)
import qualified Cardano.Ledger.Mary.Value as Mary
import Cardano.Ledger.Pretty
  ( PDoc,
    PrettyA (..),
    ppAddr,
    ppCoin,
    ppDCert,
    ppRecord,
    ppSafeHash,
    ppSet,
    ppSexp,
    ppStrictMaybe,
    ppStrictSeq,
    ppTxIn,
    ppUpdate,
    ppWdrl,
  )
import Cardano.Ledger.SafeHash
  ( EraIndependentTxBody,
    EraIndependentWitnessPPData,
    HashAnnotated,
    SafeHash,
    SafeToHash,
  )
import Cardano.Ledger.Shelley.Constraints (PParamsDelta)
import Cardano.Ledger.ShelleyMA.Timelocks (ValidityInterval (..), ppValidityInterval)
import Cardano.Ledger.Val
  ( DecodeNonNegative,
    decodeMint,
    decodeNonNegative,
    encodeMint,
    isZero,
  )
import Data.Coders
import Data.Maybe (fromMaybe)
import Data.MemoBytes (Mem, MemoBytes (..), memoBytes)
import Data.Sequence.Strict (StrictSeq)
import qualified Data.Sequence.Strict as StrictSeq
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import GHC.Records (HasField (..))
import GHC.Stack (HasCallStack)
import NoThunks.Class (InspectHeapNamed (..), NoThunks)
import Shelley.Spec.Ledger.Address (Addr)
import Shelley.Spec.Ledger.BaseTypes (StrictMaybe (..))
import Shelley.Spec.Ledger.Coin (Coin)
import Shelley.Spec.Ledger.CompactAddr (CompactAddr, compactAddr, decompactAddr)
import Shelley.Spec.Ledger.Delegation.Certificates (DCert)
import Shelley.Spec.Ledger.PParams (Update)
import Shelley.Spec.Ledger.TxBody (TxIn (..), Wdrl (Wdrl), unWdrl)
import Prelude hiding (lookup)

data TxOut era
  = TxOutCompact
      {-# UNPACK #-} !(CompactAddr (Crypto era))
      !(CompactForm (Core.Value era))
      !(StrictMaybe (DataHash (Crypto era)))
  deriving (Generic)

deriving stock instance
  ( Eq (Core.Value era),
    Compactible (Core.Value era)
  ) =>
  Eq (TxOut era)

instance
  ( Show (Core.Value era)
  ) =>
  Show (TxOut era)
  where
  show = error "Not yet implemented"

deriving via InspectHeapNamed "TxOut" (TxOut era) instance NoThunks (TxOut era)

pattern TxOut ::
  ( Era era,
    Compactible (Core.Value era),
    Show (Core.Value era),
    HasCallStack
  ) =>
  Addr (Crypto era) ->
  Core.Value era ->
  StrictMaybe (DataHash (Crypto era)) ->
  TxOut era
pattern TxOut addr vl dh <-
  TxOutCompact (decompactAddr -> addr) (fromCompact -> vl) dh
  where
    TxOut addr vl dh =
      TxOutCompact
        (compactAddr addr)
        ( fromMaybe (error $ "Illegal value in txout: " <> show vl) $
            toCompact vl
        )
        dh

{-# COMPLETE TxOut #-}

type WitnessPPDataHash crypto = SafeHash crypto EraIndependentWitnessPPData

data TxBodyRaw era = TxBodyRaw
  { _inputs :: !(Set (TxIn (Crypto era))),
    _inputs_fee :: !(Set (TxIn (Crypto era))),
    _outputs :: !(StrictSeq (TxOut era)),
    _certs :: !(StrictSeq (DCert (Crypto era))),
    _wdrls :: !(Wdrl (Crypto era)),
    _txfee :: !Coin,
    _vldt :: !ValidityInterval,
    _update :: !(StrictMaybe (Update era)),
    _adHash :: !(StrictMaybe (AuxiliaryDataHash (Crypto era))),
    _mint :: !(Value (Crypto era)),
    -- The spec makes it clear that the mint field is a
    -- Cardano.Ledger.Mary.Value.Value, not a Core.Value.
    -- Operations on the TxBody in the AlonzoEra depend upon this.
    _sdHash :: !(StrictMaybe (WitnessPPDataHash (Crypto era))),
    _scriptHash :: !(StrictMaybe (AuxiliaryDataHash (Crypto era)))
  }
  deriving (Generic, Typeable)

deriving instance
  ( Eq (Core.Value era),
    CC.Crypto (Crypto era),
    Compactible (Core.Value era),
    Eq (PParamsDelta era)
  ) =>
  Eq (TxBodyRaw era)

instance
  (Typeable era, NoThunks (Core.Value era), NoThunks (PParamsDelta era)) =>
  NoThunks (TxBodyRaw era)

deriving instance
  (Era era, Show (Core.Value era), Show (PParamsDelta era)) =>
  Show (TxBodyRaw era)

newtype TxBody era = TxBodyConstr (MemoBytes (TxBodyRaw era))
  deriving (ToCBOR)
  deriving newtype (SafeToHash)

deriving newtype instance
  ( Eq (Core.Value era),
    Compactible (Core.Value era),
    CC.Crypto (Crypto era),
    Eq (PParamsDelta era)
  ) =>
  Eq (TxBody era)

deriving instance
  ( Typeable era,
    NoThunks (Core.Value era),
    NoThunks (PParamsDelta era)
  ) =>
  NoThunks (TxBody era)

deriving instance
  ( Era era,
    Compactible (Core.Value era),
    Show (Core.Value era),
    Show (PParamsDelta era)
  ) =>
  Show (TxBody era)

deriving via
  (Mem (TxBodyRaw era))
  instance
    ( Era era,
      Typeable (Core.Script era),
      Typeable (Core.AuxiliaryData era),
      Compactible (Core.Value era),
      Show (Core.Value era),
      DecodeNonNegative (Core.Value era),
      FromCBOR (Annotator (Core.Script era)),
      Core.AnnotatedData (PParamsDelta era)
    ) =>
    FromCBOR (Annotator (TxBody era))

-- The Set of constraints necessary to use the TxBody pattern
type AlonzoBody era =
  ( Era era,
    Compactible (Core.Value era),
    ToCBOR (Core.Script era),
    Core.AnnotatedData (PParamsDelta era)
  )

pattern TxBody ::
  AlonzoBody era =>
  Set (TxIn (Crypto era)) ->
  Set (TxIn (Crypto era)) ->
  StrictSeq (TxOut era) ->
  StrictSeq (DCert (Crypto era)) ->
  Wdrl (Crypto era) ->
  Coin ->
  ValidityInterval ->
  StrictMaybe (Update era) ->
  StrictMaybe (AuxiliaryDataHash (Crypto era)) ->
  Value (Crypto era) ->
  StrictMaybe (WitnessPPDataHash (Crypto era)) ->
  StrictMaybe (AuxiliaryDataHash (Crypto era)) ->
  TxBody era
pattern TxBody
  { inputs,
    txinputs_fee,
    outputs,
    txcerts,
    txwdrls,
    txfee,
    txvldt,
    txUpdates,
    txADhash,
    mint,
    sdHash,
    scriptHash
  } <-
  TxBodyConstr
    ( Memo
        TxBodyRaw
          { _inputs = inputs,
            _inputs_fee = txinputs_fee,
            _outputs = outputs,
            _certs = txcerts,
            _wdrls = txwdrls,
            _txfee = txfee,
            _vldt = txvldt,
            _update = txUpdates,
            _adHash = txADhash,
            _mint = mint,
            _sdHash = sdHash,
            _scriptHash = scriptHash
          }
        _
      )
  where
    TxBody
      inputs'
      inputs_fee'
      outputs'
      certs'
      wdrls'
      txfee'
      vldt'
      update'
      adHash'
      mint'
      sdHash'
      scriptHash' =
        TxBodyConstr $
          memoBytes
            ( encodeTxBodyRaw $
                TxBodyRaw
                  inputs'
                  inputs_fee'
                  outputs'
                  certs'
                  wdrls'
                  txfee'
                  vldt'
                  update'
                  adHash'
                  mint'
                  sdHash'
                  scriptHash'
            )

{-# COMPLETE TxBody #-}

instance (c ~ Crypto era, Era era) => HashAnnotated (TxBody era) EraIndependentTxBody c

--------------------------------------------------------------------------------
-- Serialisation
--------------------------------------------------------------------------------

instance
  ( Era era,
    Compactible (Core.Value era)
  ) =>
  ToCBOR (TxOut era)
  where
  toCBOR (TxOutCompact addr cv dh) =
    encode $
      Rec
        (TxOutCompact @era)
        !> To addr
        !> To cv
        !> To dh

instance
  ( Era era,
    DecodeNonNegative (Core.Value era),
    Show (Core.Value era),
    Compactible (Core.Value era),
    ToCBOR (PParamsDelta era)
  ) =>
  FromCBOR (TxOut era)
  where
  fromCBOR =
    decode $
      RecD TxOutCompact
        <! From
        <! D decodeNonNegative
        <! From

encodeTxBodyRaw ::
  ( Era era,
    Compactible (Core.Value era),
    ToCBOR (PParamsDelta era)
  ) =>
  TxBodyRaw era ->
  Encode ('Closed 'Sparse) (TxBodyRaw era)
encodeTxBodyRaw
  TxBodyRaw
    { _inputs,
      _inputs_fee,
      _outputs,
      _certs,
      _wdrls,
      _txfee,
      _vldt = ValidityInterval bot top,
      _update,
      _adHash,
      _mint,
      _sdHash,
      _scriptHash
    } =
    Keyed
      ( \i ifee o f t c w u mh b mi e s ->
          TxBodyRaw i ifee o c w f (ValidityInterval b t) u mh mi e s
      )
      !> Key 0 (E encodeFoldable _inputs)
      !> Key 13 (E encodeFoldable _inputs_fee)
      !> Key 1 (E encodeFoldable _outputs)
      !> Key 2 (To _txfee)
      !> encodeKeyedStrictMaybe 3 top
      !> Omit null (Key 4 (E encodeFoldable _certs))
      !> Omit (null . unWdrl) (Key 5 (To _wdrls))
      !> encodeKeyedStrictMaybe 6 _update
      !> encodeKeyedStrictMaybe 7 _adHash
      !> encodeKeyedStrictMaybe 8 bot
      !> Omit isZero (Key 9 (E encodeMint _mint))
      !> encodeKeyedStrictMaybe 11 _sdHash
      !> encodeKeyedStrictMaybe 12 _scriptHash
    where
      encodeKeyedStrictMaybe key x =
        Omit isSNothing (Key key (E (toCBOR . fromSJust) x))

      isSNothing :: StrictMaybe a -> Bool
      isSNothing SNothing = True
      isSNothing _ = False

      fromSJust :: StrictMaybe a -> a
      fromSJust (SJust x) = x
      fromSJust SNothing = error "SNothing in fromSJust"

instance
  forall era.
  ( Era era,
    Typeable (Core.Script era),
    Typeable (Core.AuxiliaryData era),
    Compactible (Core.Value era),
    Show (Core.Value era),
    DecodeNonNegative (Core.Value era),
    FromCBOR (Annotator (Core.Script era)),
    FromCBOR (Annotator (PParamsDelta era)),
    ToCBOR (PParamsDelta era)
  ) =>
  FromCBOR (Annotator (TxBodyRaw era))
  where
  fromCBOR =
    decode $
      SparseKeyed
        "TxBodyRaw"
        (pure initial)
        bodyFields
        requiredFields
    where
      initial :: TxBodyRaw era
      initial =
        TxBodyRaw
          mempty
          mempty
          StrictSeq.empty
          StrictSeq.empty
          (Wdrl mempty)
          mempty
          (ValidityInterval SNothing SNothing)
          SNothing
          SNothing
          mempty
          SNothing
          SNothing
      bodyFields :: (Word -> Field (Annotator (TxBodyRaw era)))
      bodyFields 0 =
        fieldA
          (\x tx -> tx {_inputs = x})
          (D (decodeSet fromCBOR))
      bodyFields 13 =
        fieldA
          (\x tx -> tx {_inputs_fee = x})
          (D (decodeSet fromCBOR))
      bodyFields 1 =
        fieldA
          (\x tx -> tx {_outputs = x})
          (D (decodeStrictSeq fromCBOR))
      bodyFields 2 = fieldA (\x tx -> tx {_txfee = x}) From
      bodyFields 3 =
        fieldA
          (\x tx -> tx {_vldt = (_vldt tx) {invalidHereafter = x}})
          (D (SJust <$> fromCBOR))
      bodyFields 4 =
        fieldA
          (\x tx -> tx {_certs = x})
          (D (decodeStrictSeq fromCBOR))
      bodyFields 5 = fieldA (\x tx -> tx {_wdrls = x}) From
      bodyFields 6 = fieldAA (\x tx -> tx {_update = x}) (D (fmap SJust <$> fromCBOR))
      bodyFields 7 = fieldA (\x tx -> tx {_adHash = x}) (D (SJust <$> fromCBOR))
      bodyFields 8 =
        fieldA
          (\x tx -> tx {_vldt = (_vldt tx) {invalidBefore = x}})
          (D (SJust <$> fromCBOR))
      bodyFields 9 = fieldA (\x tx -> tx {_mint = x}) (D decodeMint)
      bodyFields 11 = fieldA (\x tx -> tx {_sdHash = x}) (D (SJust <$> fromCBOR))
      bodyFields 12 =
        fieldA
          (\x tx -> tx {_scriptHash = x})
          (D (SJust <$> fromCBOR))
      bodyFields n = fieldA (\_ t -> t) (Invalid n)
      requiredFields =
        [ (0, "inputs"),
          (1, "outputs"),
          (2, "fee")
        ]

-- ====================================================
-- HasField instances to be consistent with earlier Era's

instance (Crypto era ~ c) => HasField "inputs" (TxBody era) (Set (TxIn c)) where
  getField (TxBodyConstr (Memo m _)) = Set.union (_inputs m) (_inputs_fee m)

instance HasField "outputs" (TxBody era) (StrictSeq (TxOut era)) where
  getField (TxBodyConstr (Memo m _)) = _outputs m

instance Crypto era ~ crypto => HasField "certs" (TxBody era) (StrictSeq (DCert crypto)) where
  getField (TxBodyConstr (Memo m _)) = _certs m

instance Crypto era ~ crypto => HasField "wdrls" (TxBody era) (Wdrl crypto) where
  getField (TxBodyConstr (Memo m _)) = _wdrls m

instance HasField "txfee" (TxBody era) Coin where
  getField (TxBodyConstr (Memo m _)) = _txfee m

instance HasField "update" (TxBody era) (StrictMaybe (Update era)) where
  getField (TxBodyConstr (Memo m _)) = _update m

instance (Crypto era ~ c) => HasField "compactAddress" (TxOut era) (CompactAddr c) where
  getField (TxOutCompact a _ _) = a

instance (CC.Crypto c, Crypto era ~ c) => HasField "address" (TxOut era) (Addr c) where
  getField (TxOutCompact a _ _) = decompactAddr a

instance (Core.Value era ~ val, Compactible val) => HasField "value" (TxOut era) val where
  getField (TxOutCompact _ v _) = fromCompact v

instance (Crypto era ~ c) => HasField "mint" (TxBody era) (Mary.Value c) where
  getField (TxBodyConstr (Memo m _)) = _mint m

instance
  (Crypto era ~ c) =>
  HasField "txinputs_fee" (TxBody era) (Set (TxIn c))
  where
  getField (TxBodyConstr (Memo m _)) = _inputs_fee m

-- ===================================================

ppTxOut ::
  ( Era era,
    Compactible (Core.Value era),
    Show (Core.Value era),
    PrettyA (Core.Value era)
  ) =>
  TxOut era ->
  PDoc
ppTxOut (TxOut addr val dhash) =
  ppSexp "TxOut" [ppAddr addr, prettyA val, ppStrictMaybe ppSafeHash dhash]

ppTxBody ::
  ( Era era,
    Compactible (Core.Value era),
    Show (Core.Value era),
    PrettyA (Core.Value era),
    PrettyA (PParamsDelta era)
  ) =>
  TxBody era ->
  PDoc
ppTxBody (TxBodyConstr (Memo (TxBodyRaw i ifee o c w fee vi u adh mnt sdh sch) _)) =
  ppRecord
    "TxBody(Mary or Allegra)"
    [ ("inputs", ppSet ppTxIn i),
      ("inputs_fee", ppSet ppTxIn ifee),
      ("outputs", ppStrictSeq ppTxOut o),
      ("certificates", ppStrictSeq ppDCert c),
      ("withdrawals", ppWdrl w),
      ("txfee", ppCoin fee),
      ("vldt", ppValidityInterval vi),
      ("update", ppStrictMaybe ppUpdate u),
      ("adHash", ppStrictMaybe ppSafeHash adh),
      ("mint", ppValue mnt),
      ("sdHash", ppStrictMaybe ppSafeHash sdh),
      ("scriptHash", ppStrictMaybe ppSafeHash sch)
    ]

instance
  ( Era era,
    PrettyA (Core.Value era),
    PrettyA (PParamsDelta era),
    Compactible (Core.Value era),
    Show (Core.Value era)
  ) =>
  PrettyA (TxBody era)
  where
  prettyA = ppTxBody
