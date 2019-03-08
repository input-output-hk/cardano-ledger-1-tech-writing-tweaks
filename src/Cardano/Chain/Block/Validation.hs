{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE DeriveAnyClass   #-}
{-# LANGUAGE DeriveGeneric    #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NumDecimals      #-}
{-# LANGUAGE TupleSections    #-}

module Cardano.Chain.Block.Validation
  ( updateBody
  , updateChainBoundary
  , ChainValidationState
  , cvsPreviousHash
  , initialChainValidationState
  , ChainValidationError

  -- * SigningHistory
  , SigningHistory(..)
  , updateSigningHistory
  )
where

import Cardano.Prelude

import qualified Data.ByteString.Lazy as BSL
import Data.Coerce (coerce)
import qualified Data.Map.Strict as M
import Data.Sequence (Seq(..), (<|))

import Cardano.Chain.Block.Block
  ( ABlock(..)
  , BoundaryValidationData(..)
  , blockDlgPayload
  , blockLength
  , blockProof
  , blockSlot
  )
import Cardano.Chain.Block.Header
  ( BlockSignature(..)
  , HeaderHash
  , recoverSignedBytes
  , wrapBoundaryBytes
  )
import Cardano.Chain.Common (BlockCount(..), StakeholderId, mkStakeholderId)
import qualified Cardano.Chain.Delegation as Delegation
import qualified Cardano.Chain.Delegation.Payload as DlgPayload
import Cardano.Chain.Delegation.Validation
  (initialInterfaceState, updateDelegation)
import Cardano.Chain.Genesis as Genesis
  ( Config(..)
  , GenesisWStakeholders(..)
  , configBootStakeholders
  , configEpochSlots
  , configGenesisHeaderHash
  , configK
  , configSlotSecurityParam
  )
import Cardano.Chain.Slotting (flattenSlotId)
import Cardano.Crypto
  ( PublicKey
  , hash
  , hashRaw
  )


--------------------------------------------------------------------------------
-- SigningHistory
--------------------------------------------------------------------------------

-- | The history of signers in the last @K@ blocks
--
--   We maintain a map of the number of blocks signed for each stakeholder to
--   improve performance. The sum of the `BlockCount`s in the map should be
--   equal to the length of the sequence.
data SigningHistory = SigningHistory
  { shK                 :: !BlockCount
  , shSigningQueue      :: !(Seq StakeholderId)
  , shStakeholderCounts :: !(Map StakeholderId BlockCount)
  } deriving (Eq, Show, Generic, NFData)

-- | Update the `SigningHistory` with a new signer, removing the oldest value if
--   the sequence is @K@ blocks long
updateSigningHistory :: PublicKey -> SigningHistory -> SigningHistory
updateSigningHistory pk sh
  | length (shSigningQueue sh) < fromIntegral (shK sh) = sh & addStakeholderIn
  | otherwise = sh & addStakeholderIn & removeStakeholderOut
 where
  stakeholderIn = mkStakeholderId pk

  addStakeholderIn :: SigningHistory -> SigningHistory
  addStakeholderIn sh' = sh'
    { shSigningQueue      = stakeholderIn <| shSigningQueue sh'
    , shStakeholderCounts = M.adjust
      (+ 1)
      stakeholderIn
      (shStakeholderCounts sh')
    }

  removeStakeholderOut :: SigningHistory -> SigningHistory
  removeStakeholderOut sh' = case shSigningQueue sh' of
    Empty -> sh'
    rest :|> stakeholderOut -> sh'
      { shSigningQueue      = rest
      , shStakeholderCounts = M.adjust
        (subtract 1)
        stakeholderOut
        (shStakeholderCounts sh')
      }


--------------------------------------------------------------------------------
-- ChainValidationState
--------------------------------------------------------------------------------

data ChainValidationState = ChainValidationState
  { cvsSigningHistory  :: !SigningHistory
  , cvsPreviousHash    :: !(Maybe HeaderHash)
  , cvsDelegationState :: !Delegation.InterfaceState
  } deriving (Eq, Show, Generic, NFData)

initialChainValidationState
  :: MonadError Delegation.SchedulingError m
  => Genesis.Config
  -> m ChainValidationState
initialChainValidationState config = do
  delegationState <- initialInterfaceState config
  pure $ ChainValidationState
    { cvsSigningHistory  = SigningHistory
      { shK = configK config
      , shStakeholderCounts = M.fromList
        . map (, 0)
        . M.keys
        . getGenesisWStakeholders
        $ configBootStakeholders config
      , shSigningQueue = Empty
      }
    , cvsPreviousHash    = Nothing
    , cvsDelegationState = delegationState
    }


--------------------------------------------------------------------------------
-- ChainValidationError
--------------------------------------------------------------------------------

data ChainValidationError

  = ChainValidationBoundaryTooLarge
  -- ^ The size of an epoch boundary block exceeds the limit

  | ChainValidationBlockTooLarge
  -- ^ The size of a regular block exceeds the limit

  | ChainValidationDelegationPayloadError Text
  -- ^ There is a problem with the delegation payload signature

  | ChainValidationInvalidDelegation PublicKey PublicKey
  -- ^ The delegation used in the signature is not valid according to the ledger

  | ChainValidationInvalidHash HeaderHash HeaderHash
  -- ^ The hash of the previous block does not match the value in the header

  | ChainValidationInvalidSignature BlockSignature
  -- ^ The signature of the block is invalid

  | ChainValidationDelegationProofError
  -- ^ The delegation proof does not correspond to the delegation payload

  | ChainValidationDelegationSchedulingError Delegation.SchedulingError
  -- ^ A delegation certificate failed validation in the ledger layer

  | ChainValidationSignatureLight
  -- ^ A block is using unsupported lightweight delegation

  | ChainValidationTooManyDelegations PublicKey
  -- ^ The delegator for this block has delegated in too many recent blocks

  deriving (Eq, Show)


--------------------------------------------------------------------------------
-- Validation Functions
--------------------------------------------------------------------------------

updateChainBoundary
  :: MonadError ChainValidationError m
  => Genesis.Config
  -> ChainValidationState
  -> BoundaryValidationData ByteString
  -> m ChainValidationState
updateChainBoundary config cvs bvd = do
  let
    prevHash =
      fromMaybe (configGenesisHeaderHash config) (cvsPreviousHash cvs)

  -- Validate the previous block hash of 'b'
  (boundaryPrevHash bvd == prevHash)
    `orThrowError` ChainValidationInvalidHash prevHash (boundaryPrevHash bvd)

  -- Validate that the block is within the size bounds
  (boundaryBlockLength bvd <= 2e6)
    `orThrowError` ChainValidationBoundaryTooLarge

  -- Update the previous hash
  pure $ cvs
    { cvsPreviousHash =
      Just
      . coerce
      . hashRaw
      . BSL.fromStrict
      . wrapBoundaryBytes
      $ boundaryHeaderBytes bvd
    }

-- | This is an implementation of the BBODY rule as per the chain specification.
--   Compared to `updateChain`, this does not validate any header level checks, nor
--   does it carry out anything which might be considered part of the protocol.
updateBody
  :: MonadError ChainValidationError m
  => Genesis.Config
  -> ChainValidationState
  -> ABlock ByteString
  -> m ChainValidationState
updateBody config cvs b = do

  -- Validate the block size
  -- TODO Max block size should come from protocol params
  let maxBlockSize :: Int64
      maxBlockSize = 2e6 in
    blockLength b <= maxBlockSize `orThrowError` ChainValidationBlockTooLarge

  -- Validate the delegation payload signature
  proofDelegation (blockProof b) == hash (const () <$> blockDlgPayload b)
    `orThrowError` ChainValidationDelegationProofError

  delegationState' <-
      updateDelegation config slot d delegationState certificates
        `wrapError` ChainValidationDelegationSchedulingError

  pure $ cvs
    {cvsDelegationState = delegationState'}
 where
  slot = flattenSlotId (configEpochSlots config) $ blockSlot b
  d    = configSlotSecurityParam config

  delegationState = cvsDelegationState cvs

  certificates = DlgPayload.getPayload $ blockDlgPayload b
