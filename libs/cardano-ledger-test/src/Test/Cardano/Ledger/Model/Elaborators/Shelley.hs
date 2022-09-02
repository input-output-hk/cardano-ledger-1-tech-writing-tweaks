{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Test.Cardano.Ledger.Model.Elaborators.Shelley where

import qualified Cardano.Crypto.DSIGN.Class as DSIGN
import qualified Cardano.Crypto.KES.Class as KES
import Cardano.Crypto.Util (SignableRepresentation)
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.BaseTypes (Globals (..), activeSlotVal, epochInfoPure)
import Cardano.Ledger.Coin (Coin (..))
import qualified Cardano.Ledger.Core as Core
import Cardano.Ledger.Crypto (DSIGN, KES)
import Cardano.Ledger.Era (EraCrypto)
import Cardano.Ledger.Keys (GenDelegPair, KeyHash, KeyRole (..))
import Cardano.Ledger.Shelley (ShelleyEra)
import Cardano.Ledger.Shelley.API.Genesis (initialState)
import Cardano.Ledger.Shelley.API.Mempool (ApplyTxError (..))
import Cardano.Ledger.Shelley.Genesis
  ( ShelleyGenesis (..),
    emptyGenesisStaking,
  )
import qualified Cardano.Ledger.Shelley.LedgerState as LedgerState
import qualified Cardano.Ledger.Shelley.PParams as Shelley
import Cardano.Ledger.Shelley.Rules
  ( ShelleyLedgerPredFailure (..),
    ledgerIx,
    ShelleyUtxoPredFailure (..),
    ShelleyUtxowPredFailure (..),
  )
import Cardano.Ledger.Shelley.Tx (ShelleyTx (ShelleyTx), ShelleyTxBody (ShelleyTxBody))
import qualified Cardano.Ledger.Shelley.Tx as Shelley
import Cardano.Ledger.Shelley.TxWits as Shelley
import Cardano.Protocol.TPraos.API (PraosCrypto)
import Cardano.Slotting.EpochInfo.API (epochInfoSize)
import Cardano.Slotting.Slot (EpochNo (..))
import qualified Control.Monad.Except as Except
import qualified Control.Monad.State.Class as State
import qualified Control.Monad.Trans.State as State hiding (get, gets, state)
import Data.Functor.Identity (Identity (..))
import Data.Group (Group (..))
import qualified Data.ListMap as LM
import qualified Data.Map.Strict as Map
import Data.Maybe.Strict (StrictMaybe (..))
import Data.Proxy
import Data.Time.Clock (secondsToNominalDiffTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Void (absurd)
import qualified GHC.Records as GHC
import Test.Cardano.Ledger.Model.API
  ( ModelBlock (..),
  )
import Test.Cardano.Ledger.Model.BaseTypes
  ( ModelValue (..),
  )
import Test.Cardano.Ledger.Model.Elaborators
import Test.Cardano.Ledger.Model.FeatureSet
  ( FeatureSet (..),
    FeatureSupport (..),
    IfSupportsMint (..),
    IfSupportsPlutus (..),
    IfSupportsScript (..),
    IfSupportsTimelock (..),
    KnownRequiredFeatures,
    TyScriptFeature (..),
    TyValueExpected (..),
  )
import Test.Cardano.Ledger.Model.PParams (ModelPParams, ModelPParamsF (..))
import Test.Cardano.Ledger.Model.Rules (ModelPredicateFailure (..))
import Test.Cardano.Ledger.Model.Value
  ( evalModelValue,
  )

instance
  ( PraosCrypto c,
    KES.Signable (KES c) ~ SignableRepresentation,
    DSIGN.Signable (DSIGN c) ~ SignableRepresentation
  ) =>
  ElaborateEraModel (ShelleyEra c)
  where
  type EraFeatureSet (ShelleyEra c) = 'FeatureSet 'ExpectAdaOnly ('TyScriptFeature 'False 'False)

  reifyValueConstraint = ExpectedValueTypeC_Simple

  makeInitialState globals mpp genDelegs utxo0 = nes
    where
      pp = elaborateShelleyPParams mpp
      additionalGenesesConfig = ()
      sg = fromShelleyGlobals globals pp genDelegs utxo0
      nes = initialState sg additionalGenesesConfig

  makeTimelockScript _ (NoTimelockSupport x) = absurd x
  makePlutusScript _ (NoPlutusSupport x) = absurd x
  makeExtendedTxOut _ _ (NoPlutusSupport x) = absurd x

  toEraPredicateFailure = \case
    ModelValueNotConservedUTxO (ModelValue x) (ModelValue y) -> State.evalState $
      do
        x' <- evalModelValue (lookupModelValue noScriptAction) x
        y' <- evalModelValue (lookupModelValue noScriptAction) y
        pure $
          ApplyBlockTransitionError_Tx $
            ApplyTxError
              [UtxowFailure (UtxoFailure (ValueNotConservedUTxO x' y'))]

  makeTxBody _ (TxBodyArguments maxTTL fee ins outs dcerts wdrl (NoMintSupport ()) (NoPlutusSupport ()) (NoPlutusSupport ()) (NoPlutusSupport ())) =
    ShelleyTxBody
      { Shelley._inputs = ins,
        Shelley._outputs = outs,
        Shelley._certs = dcerts,
        Shelley._wdrls = wdrl,
        Shelley._txfee = fee,
        Shelley._ttl = maxTTL,
        Shelley._txUpdate = SNothing,
        Shelley._mdHash = SNothing
      }

  makeTx _ realTxBody (TxWitnessArguments wits (NoScriptSupport ()) (NoPlutusSupport ()) (NoPlutusSupport ())) =
    ShelleyTx realTxBody (mempty {Shelley.addrWits = wits}) SNothing
  elaborateBlock globals =
    State.runState . Except.runExceptT . \case
      mblock@(ModelBlock mslot mtxSeq) -> do
        currentEpoch <- use $ _2 . eesCurrentEpoch
        let slot = runIdentity (epochInfoFirst ei currentEpoch) + mslot
            ei = epochInfoPure globals
            ttl = succ slot

        unless (currentEpoch == runIdentity (epochInfoEpoch ei slot)) $ error $ "model slot out of range: " <> show mslot
        _2 . eesCurrentSlot .= slot
        -- tick the model
        lift $ zoom _1 $ State.state $ \nes0 -> ((), applyTick globals nes0 slot)
        txSeq ::
          [Core.Tx era] <-
          for mtxSeq $ \tx -> Except.ExceptT $ State.state $ elaborateTx (Proxy :: Proxy era) globals ttl tx

        mempoolEnv <- (\(nes0, _) -> mkMempoolEnv nes0 slot) <$> get

        -- apply the transactions.

        ifor_ (zip txSeq mtxSeq) $ \txIx (tx, mtx) -> do
          (nes0, ems0) <- get
          (mps', _) <- liftApplyTxError (ElaborateApplyTxError tx mtx nes0 ems0) $ applyTx globals mempoolEnv {ledgerIx = toEnum txIx} (view mempoolState nes0) tx

          let nes1 = set mempoolState mps' nes0
              adaSupply = totalAdaES (LedgerState.nesEs nes1)
          unless (adaSupply == Coin (toInteger $ maxLovelaceSupply globals)) $
            _2 . eesStats
              <>= mempty
                { _eeStats_adaConservedErrors = [(globals, mempoolEnv, (view mempoolState nes0), tx)]
                }
          put (nes1, ems0)

        _2 . eesModel %= execModelM (applyModelBlock mblock) globals

        compareModelLedger (cmsError mblock)

        pure ()

fromShelleyGlobals ::
  Globals ->
  Shelley.ShelleyPParams era ->
  Map.Map (KeyHash 'Genesis (EraCrypto era)) (GenDelegPair (EraCrypto era)) ->
  Map.Map (Addr (EraCrypto era)) Coin ->
  ShelleyGenesis era
fromShelleyGlobals globals pp genDelegs initialFunds =
  ShelleyGenesis
    { sgSystemStart = (posixSecondsToUTCTime 0),
      sgNetworkMagic = 1, -- genNetworkMagic
      sgNetworkId = networkId globals,
      sgActiveSlotsCoeff = activeSlotVal $ activeSlotCoeff globals,
      sgSecurityParam = securityParameter globals,
      sgEpochLength = runIdentity $ flip epochInfoSize (EpochNo 1) $ epochInfoPure globals,
      sgSlotsPerKESPeriod = slotsPerKESPeriod globals,
      sgMaxKESEvolutions = maxKESEvo globals,
      sgSlotLength = (secondsToNominalDiffTime 1),
      sgUpdateQuorum = quorum globals,
      sgMaxLovelaceSupply = maxLovelaceSupply globals,
      sgProtocolParams = pp,
      sgGenDelegs = genDelegs, --  genGenesisDelegationList
      sgInitialFunds = LM.ListMap $ Map.toList initialFunds, -- genFundsList
      sgStaking = emptyGenesisStaking -- genStaking
    }

elaborateShelleyPParams ::
  KnownRequiredFeatures (EraFeatureSet era) =>
  ModelPParams (EraFeatureSet era) ->
  Shelley.ShelleyPParams era
elaborateShelleyPParams mpp =
  let minUTxOValue =
        bifoldMapSupportsFeature id (`pow` (29 :: Integer)) $ runIdentity $ _modelPParams_coinsPerUTxOWord mpp
   in Shelley.emptyPParams
        { Shelley._nOpt = GHC.getField @"_nOpt" mpp,
          Shelley._a0 = GHC.getField @"_a0" mpp,
          Shelley._rho = GHC.getField @"_rho" mpp,
          Shelley._tau = GHC.getField @"_tau" mpp,
          Shelley._d = GHC.getField @"_d" mpp,
          Shelley._minfeeA = GHC.getField @"_minfeeA" mpp,
          Shelley._minfeeB = GHC.getField @"_minfeeB" mpp,
          -- , Shelley._maxBBSize = GHC.getField @"_maxBBSize" mpp
          Shelley._maxTxSize = GHC.getField @"_maxTxSize" mpp,
          -- , Shelley._maxBHSize = GHC.getField @"_maxBHSize" mpp
          Shelley._keyDeposit = GHC.getField @"_keyDeposit" mpp,
          Shelley._poolDeposit = GHC.getField @"_poolDeposit" mpp,
          -- , Shelley._eMax = GHC.getField @"_eMax" mpp
          -- , Shelley._extraEntropy = GHC.getField @"_extraEntropy" mpp
          Shelley._protocolVersion = GHC.getField @"_protocolVersion" mpp,
          Shelley._minUTxOValue = minUTxOValue,
          Shelley._minPoolCost = GHC.getField @"_minPoolCost" mpp
        }
