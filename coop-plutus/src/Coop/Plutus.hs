{-# LANGUAGE BlockArguments #-}
{-# OPTIONS_GHC -Wno-unused-do-bind #-}

module Coop.Plutus (
  mkFsMp,
  fsV,
  mkAuthMp,
  certV,
  mkCertMp,
  pmustSpendAtLeastAa,
) where

import Coop.Plutus.Aux (pcurrencyTokenQuantity, pcurrencyValue, pdatumFromTxOut, pdjust, pdnothing, pfindMap, pfoldTxInputs, pfoldTxOutputs, pfoldTxRefs, phasCurrency, pmaybeData, pmustBeSignedBy, pmustBurnOwnSingletonValue, pmustMintCurrency, pmustPayCurrencyWithDatumTo, pmustSpendAtLeast, pmustValidateAfter, pownCurrencySymbol, ptryFromData, punit)
import Coop.Plutus.Types (PAuthMpParams, PAuthMpRedeemer (PAuthMpBurn, PAuthMpMint), PAuthParams, PCertDatum, PCertMpParams, PCertMpRedeemer (PCertMpBurn, PCertMpMint), PFsDatum, PFsMpParams, PFsMpRedeemer (PFsMpBurn, PFsMpMint))
import Plutarch (POpaque, pmatch, popaque)
import Plutarch.Api.V1.Value (passertPositive, pnormalize, pvalueOf)
import Plutarch.Api.V1.Value qualified as PValue
import Plutarch.Api.V2 (
  AmountGuarantees (NonZero, Positive),
  KeyGuarantees (Sorted),
  PCurrencySymbol,
  PMaybeData,
  PMintingPolicy,
  PTokenName (PTokenName),
  PTuple,
  PTxInInfo,
  PTxOut,
  PValidator,
  PValue,
 )
import Plutarch.Api.V2.Contexts (PScriptContext)
import Plutarch.Bool (pif)
import Plutarch.Crypto (pblake2b_256)
import Plutarch.Extra.Interval (pcontains)
import Plutarch.Monadic qualified as P
import Plutarch.Num (PNum (pnegate, (#+)))
import Plutarch.Prelude (ClosedTerm, PAsData, PBuiltinList, PByteString, PEq ((#==)), PInteger, PListLike (pcons, pnil), PPair (PPair), PPartialOrd ((#<), (#<=)), Term, pcon, pconsBS, pfield, pfoldl, pfromData, phoistAcyclic, plam, plet, pletFields, ptrace, ptraceError, (#), (#$), type (:-->))
import PlutusTx.Prelude (Group (inv))
import Prelude (Monoid (mempty), Semigroup ((<>)), ($))

{- | Validates spending from @FsV

- check that 'own' spent $FS token is spent and burned (FsMpBurn checks the rest)

TODO: Test 'other-mint-redeemer' vulnerability with psm or Plutip
-}
fsV :: ClosedTerm PValidator
fsV = phoistAcyclic $
  plam $ \_ _ ctx -> ptrace "@FsV" P.do
    _ <- plet $ pmustBurnOwnSingletonValue # ctx
    ptrace "@CertV: Own spent singleton value is burned" $ popaque punit

-- | Minting policy that validates minting and burning of $FS tokens
mkFsMp :: ClosedTerm (PAsData PFsMpParams :--> PMintingPolicy)
mkFsMp = phoistAcyclic $
  plam $ \params red ctx -> ptrace "FsMp" P.do
    red' <- plet $ pfromData (ptryFromData @PFsMpRedeemer red)

    pmatch red' \case
      PFsMpBurn _ -> fsMpBurn # pfromData params # ctx
      PFsMpMint _ -> fsMpMint # pfromData params # ctx

{- | Validates burning $FS tokens

- check each input and accumulate $FS tokens
  - skip if doesn't hold $FS token
  - check the trx is signed by the submitter as indicated in the FsDatum
  - check that the trx validates after time as indicated in the FsDatum
  - accumulate validated $FS token
- check that all accumulated spent $FS tokens are burned

NOTE: @FsV delegates spending validation to FsMp
-}
fsMpBurn :: ClosedTerm (PFsMpParams :--> PScriptContext :--> POpaque)
fsMpBurn = phoistAcyclic $
  plam $ \_ ctx -> ptrace "FsMp burn" P.do
    ctx' <- pletFields @'["txInfo", "purpose"] ctx
    ownCs <- plet $ pownCurrencySymbol # ctx'.purpose
    minted <- plet $ pfield @"mint" # ctx'.txInfo

    let foldFn shouldBurn txInInfo = P.do
          txOut <- plet $ pfield @"resolved" # txInInfo
          txIn <- pletFields @'["value", "address"] $ pfield @"resolved" # txInInfo
          -- WARN(Andrea): this will error out on non-FsDatum inputs, such as wallet ones to cover fees.
          --               The comment below refers to this line.
          fsDatum <- pletFields @'["fd'submitter", "fd'gcAfter", "fd'fsId"] $ pdatumFromTxOut @PFsDatum # ctx # txOut

          pif
            (phasCurrency # ownCs # txIn.value)
            ( ptrace "FsMp burn: Found own input" P.do
                _ <- plet $ pmustBeSignedBy # ctx # fsDatum.fd'submitter
                ptrace "FsMp burn: Submitter signed"

                _ <- plet $ pmustValidateAfter # ctx # fsDatum.fd'gcAfter
                ptrace "FsMp burn: Time validates"

                ownSpent <- plet $ pcurrencyValue # ownCs # txIn.value
                shouldBurn <> inv ownSpent
            )
            (ptrace "FsMp burn: Skipping foreign input" shouldBurn)

    -- Contains negative quantities
    -- WARN[Andrea]: will fail parsing a `fsDatum` if non-fsV inputs are present.
    --               It's possible extra pure Ada ones are needed to pay fees?
    shouldBurnTotal <- plet $ pfoldTxInputs # ctx # plam foldFn # mempty
    ownMinted <- plet $ pcurrencyValue # ownCs # minted
    pif
      (ownMinted #== shouldBurnTotal)
      (ptrace "FsMp burn: $FS spent are valid and burned" $ popaque punit)
      (ptraceError "FsMp mint: $FS spent must be valid and burned")

{- | Validates minting of $FS tokens.

- check all $AUTH inputs against their corresponding $CERT inputs 'referenced' at @CertV
- with all the valid $AUTH inputs proceed to check $FS outputs paid to @FsV
  - each $FS output MUST be exclusively authenticated by one $AUTH input
-}
fsMpMint :: ClosedTerm (PFsMpParams :--> PScriptContext :--> POpaque)
fsMpMint = phoistAcyclic $
  plam $ \params ctx -> ptrace "FsMp mint" P.do
    validAuthInputs <- plet $ validateAuthInputs # (pfield @"fmp'authParams" # params) # ctx
    ptrace "FsMp mint: Validated authentication inputs"

    ctx' <- pletFields @'["purpose"] ctx
    ownCs <- plet $ pownCurrencySymbol # ctx'.purpose

    PPair fsToMint restAuths <-
      pmatch $
        pfoldTxOutputs
          # ctx
          # (fsMintParseOutput # params # ctx # ownCs)
          # pcon (PPair mempty validAuthInputs)
    ptrace "FsMp mint: Validated and authenticated Fact Statement outputs"

    _ <-
      plet $
        pif
          (restAuths #== pnil)
          (ptrace "FsMp mint: Auth inputs are all used" punit)
          (ptraceError "FsMp mint: Auth inputs must ALL be used")

    _ <- plet $ pmustMintCurrency # ctx # ownCs # fsToMint
    ptrace "FsMp mint: $FS minted are paid to @FsV" $ popaque punit

-- | Skips foreign inputs and processes $FS inputs.
fsMintParseOutput ::
  Term
    s
    ( PFsMpParams
        :--> PScriptContext
        :--> PCurrencySymbol
        :--> PPair (PValue 'Sorted 'NonZero) (PBuiltinList PTxInInfo)
        :--> PTxOut
        :--> PPair (PValue 'Sorted 'NonZero) (PBuiltinList PTxInInfo)
    )
fsMintParseOutput = phoistAcyclic $
  plam $ \params ctx ownCs acc txOut -> ptrace "fsMintParseOutput" P.do
    txOut' <- pletFields @'["value"] txOut

    hasOwnCs <- plet $ phasCurrency # ownCs # txOut'.value
    pif
      hasOwnCs
      (ptrace "fsMintParseOutput: Found own token in the output" $ fsMintParseOutputWithFs # params # ctx # ownCs # acc # txOut)
      (ptrace "fsMintParseOutput: Skipping foreign output" acc)

{- | Handles a transaction output that holds an $FS token.

- check that 1 $FS is minted and associated with a valid and unused $AUTH
  - $FS token name is formed by `hashTxInput` of the associated $AUTH input
- check that 1 $FS is sent to FsV
- accumulate valid paid $FS tokens
-}
fsMintParseOutputWithFs ::
  Term
    s
    ( PFsMpParams
        :--> PScriptContext
        :--> PCurrencySymbol
        :--> PPair (PValue 'Sorted 'NonZero) (PBuiltinList PTxInInfo)
        :--> PTxOut
        :--> PPair (PValue 'Sorted 'NonZero) (PBuiltinList PTxInInfo)
    )
fsMintParseOutputWithFs = phoistAcyclic $
  plam $ \params ctx ownCs acc txOut -> ptrace "fsMintParseOutputWithFs" P.do
    txOut' <- pletFields @'["value", "address"] txOut
    fsVAddr <- plet $ pfield @"fmp'fsVAddress" # params
    PPair fsToMint unusedAuthInputs <- pmatch acc

    _ <- plet $ pdatumFromTxOut @PFsDatum # ctx # txOut
    _ <- plet $ ptrace "fsMintParseOutputWithFs: Valid FsDatum attached" punit

    _ <-
      plet $
        pif
          (txOut'.address #== fsVAddr)
          (ptrace "fsMintParseOutputWithFs: Output sent to FsV" punit)
          (ptraceError "fsMintParseOutputWithFs: Output must be sent to FsV")

    ownValue <- plet $ pcurrencyValue # ownCs # txOut'.value

    let matchWithAuth acc' authInput = P.do
          PPair mayFsTn unusedAuthInputs' <- pmatch acc'

          pmaybeData
            mayFsTn
            ( P.do
                -- Create a unique $FS token name and check if it corresponds to an $AUTH inputs
                fsTn <- plet $ pcon $ PTokenName (phashInput # authInput)
                pif
                  (ownValue #== (PValue.psingleton # ownCs # fsTn # 1))
                  (ptrace "fsMintParseOutputWithFs: Found 1 $FS token" $ pcon $ PPair (pdjust fsTn) unusedAuthInputs')
                  (ptrace "ala" $ pcon $ PPair pdnothing (pcons # authInput # unusedAuthInputs'))
            )
            (\_ -> pcon $ PPair mayFsTn (pcons # authInput # unusedAuthInputs'))

    PPair mayFsTn unusedAuthInputs' <-
      pmatch $
        pfoldl
          # plam matchWithAuth
          # pcon
            ( PPair
                (pdnothing :: Term s (PMaybeData PTokenName))
                (pnil :: Term s (PBuiltinList PTxInInfo))
            )
          # unusedAuthInputs

    pmaybeData
      mayFsTn
      (ptraceError "fsMintParseOutputWithFs: $FS must have a token name formed from a matching $AUTH input")
      ( \fsTn -> ptrace "fsMintParseOutputWithFs: $FS validated" $ pcon $ PPair (fsToMint <> PValue.psingleton # ownCs # fsTn # 1) unusedAuthInputs'
      )

{- | phashInput creates a unique bytestring from the given transaction input

- does blake2b_256 (txId `concat` ix)
-}
phashInput :: Term s (PTxInInfo :--> PByteString)
phashInput = phoistAcyclic $
  plam $ \inInfo -> P.do
    txId <- plet $ pfield @"_0" # (pfield @"id" # (pfield @"outRef" # inInfo))
    txIdx <- plet $ pfield @"idx" # (pfield @"outRef" # inInfo)
    pif
      (txIdx #< 256)
      (pblake2b_256 # (pconsBS # txIdx # txId))
      (ptraceError "phashInput: Transaction output index must fit in an octet")

{- | Validates $AUTH inputs against associated $CERT reference inputs

- check $AUTH inputs for validity against their corresponding $CERT input
- check that $AUTH spent is also burned
- accumulates $AUTH inputs

Notes:

- $CERT is a unique token locked @CertV that authenticating scripts can reference
- $AUTH is minted in batches and associated with a $CERT token via the token name
-}
validateAuthInputs ::
  Term
    s
    ( PAuthParams
        :--> PScriptContext
        :--> PBuiltinList PTxInInfo
    )
validateAuthInputs = phoistAcyclic $
  plam $ \params ctx -> ptrace "parseAuthInputs" P.do
    validCerts <- plet $ parseCertReferences # params # ctx
    authTokenCs <- plet $ pfield @"ap'authTokenCs" # params

    let foldFn acc txIn = P.do
          txInVal <- plet $ pfield @"value" # (pfield @"resolved" # txIn)

          hasAuthCs <- plet $ phasCurrency # authTokenCs # txInVal
          pif
            hasAuthCs
            (ptrace "parseAuthInputs: Found $AUTH token in the input" $ parseInputWithAuth # ctx # authTokenCs # validCerts # acc # txIn)
            (ptrace "parseAuthInputs: Skipping non $AUTH input" acc)

    PPair validAuthInputs authTokensToBurn <-
      pmatch $
        pfoldTxInputs
          # ctx
          # plam foldFn
          # pcon (PPair pnil mempty)

    -- Contains negative quantities
    _ <- plet $ pmustMintCurrency # ctx # authTokenCs # authTokensToBurn
    ptrace "parseAuthInputs: Spent $AUTH tokens burned" validAuthInputs

{- | Handles a transaction input that holds an $AUTH token

- check that there's at least one $AUTH token that's associated with a valid Certificate
- accumulates 1 $AUTH token to burn
-}
parseInputWithAuth ::
  Term
    s
    ( PScriptContext
        :--> PCurrencySymbol
        :--> PBuiltinList PCertDatum
        :--> PPair (PBuiltinList PTxInInfo) (PValue 'Sorted 'NonZero)
        :--> PTxInInfo
        :--> PPair (PBuiltinList PTxInInfo) (PValue 'Sorted 'NonZero)
    )
parseInputWithAuth = phoistAcyclic $
  plam $ \_ authTokenCs certs acc txIn -> ptrace "parseInputWithAuth" P.do
    txInOut <- plet $ pfield @"resolved" # txIn
    txInVal <- plet $ pnormalize # (pfield @"value" # txInOut)

    mayAuthTn <-
      plet $
        pfindMap
          # plam
            ( \certDat ->
                plet
                  (pcon (PTokenName $ pfield @"cert'id" # certDat))
                  ( \authTn ->
                      pif
                        (0 #< (pvalueOf # txInVal # authTokenCs # authTn)) -- NOTE: Contains at least 1 $AUTH (the rest can be paid back)
                        (pdjust authTn)
                        pdnothing
                  )
            )
          # certs

    pmaybeData
      mayAuthTn
      (ptraceError "parseInputWithAuth: $AUTH must be validated with a $CERT")
      ( \authTn -> ptrace "parseInputWithAuth: $AUTH validated with a certificate" P.do
          PPair validAuthInputs shouldBeBurned <- pmatch acc
          validAuthInputs' <- plet $ pcons # txIn # validAuthInputs
          shouldBeBurned' <- plet $ shouldBeBurned <> PValue.psingleton # authTokenCs # authTn # (pnegate # 1)
          pcon $ PPair validAuthInputs' shouldBeBurned'
      )

parseCertReferences ::
  Term
    s
    ( PAuthParams
        :--> PScriptContext
        :--> PBuiltinList PCertDatum
    )
parseCertReferences = phoistAcyclic $
  plam $ \params ctx -> ptrace "parseCertReferences" $ P.do
    certTokenCs <- plet $ pfield @"ap'certTokenCs" # params

    let foldFn acc txInInfo = P.do
          txInVal <- plet $ pfield @"value" # (pfield @"resolved" # txInInfo)
          certVal <- plet $ pcurrencyValue # certTokenCs # txInVal
          pif
            (certVal #== mempty)
            (ptrace "parseCertReferences: Skipping non $CERT input" acc)
            (ptrace "parseCertReferences: Found $CERT input" $ parseRefWithCert # ctx # certTokenCs # (passertPositive # certVal) # acc # txInInfo)

    certInputs <- plet $ pfoldTxRefs # ctx # plam foldFn # pnil
    ptrace "parseCertReferences: All referenced certs are valid" certInputs

{- | Handles a transaction input that holds an $CERT token

- check that the transaction's validation range is contained withing the Certificate's validity range
- check that the Certificate ref input has 1 $CERT token with appropriate ID (TokenName)
- accumulate valid CertDatum
-}
parseRefWithCert ::
  Term
    s
    ( PScriptContext
        :--> PCurrencySymbol
        :--> PValue 'Sorted 'Positive
        :--> PBuiltinList PCertDatum
        :--> PTxInInfo
        :--> PBuiltinList PCertDatum
    )
parseRefWithCert = phoistAcyclic $
  plam $ \ctx certTokenCs certVal acc txInInfo -> ptrace "parseRefWithCert" P.do
    txIn <- plet $ pfield @"resolved" # txInInfo

    certDat' <- plet $ (pdatumFromTxOut @PCertDatum) # ctx # txIn
    certDat <- pletFields @'["cert'validity", "cert'id"] certDat'

    _ <-
      plet $
        pif
          (pvalueOf # certVal # certTokenCs # pcon (PTokenName certDat.cert'id) #== 1)
          (ptrace "parseRefWithCert: $CERT token name matched CertDatum ID" punit)
          (ptraceError "parseRefWithCert: $CERT token name must match CertDatum ID")

    ctx' <- pletFields @'["txInfo"] ctx
    txInfo <- pletFields @'["validRange"] ctx'.txInfo
    pif
      (pcontains # certDat.cert'validity # txInfo.validRange)
      (ptrace "parseRefWithCert: cert is valid" $ pcons # certDat' # acc)
      (ptraceError "parseRefWithCert: cert is invalid")

{- | Authentication scripts

Authentication works with 3 different tokens, namely $AA, $AUTH and $CERT.

- $AA is the Authentication Authority token that is owned by the 'admin' and is
where the security of the entire system relies on. It's used with AuthMp to authorize minting of new $AUTH/$CERT tokens.

- $AUTH is the Authentication Grant token that is minted only if authorized by the
\$AA holder. These tokens can be minted in batches and sent to any number of operational
(ie. hot) wallets.

- $CERT is a Certificate token that is associated with $AUTH tokens via an identifier that is
stored in token name part of both tokens. It's sole purpose is to hold some information about $AUTH that the
authenticating scripts CAN use to validate $AUTH inputs. These are locked @CertV.

- $CERT-RDMR is a token used to collect the no longer valid $CERT output @CertV

- @CertV is a script where $CERT tokens are locked at and authenticating scripts can 'reference' these outputs when performing validation.
-}

{- | Validates spending from @CertV

- check that 'own' spent $CERT token is spent and burned (CertMpBurn checks the rest)

TODO: Test 'other-mint-redeemer' vulnerability with psm or Plutip
-}
certV :: ClosedTerm PValidator
certV = phoistAcyclic $
  plam $ \_ _ ctx -> ptrace "@CertV" P.do
    _ <- plet $ pmustBurnOwnSingletonValue # ctx
    ptrace "@CertV: Own spent singleton value is burned" $ popaque punit

-- | $CERT minting policy
mkCertMp :: ClosedTerm (PAsData PCertMpParams :--> PMintingPolicy)
mkCertMp = phoistAcyclic $
  plam $ \params red ctx -> ptrace "CertMp" P.do
    red' <- plet $ pfromData (ptryFromData @PCertMpRedeemer red)

    pmatch red' \case
      PCertMpBurn _ -> certMpBurn # ctx
      PCertMpMint _ -> certMpMint # pfromData params # ctx

{- | Validates burning of $CERT tokens

For each $CERT input
- check the transaction validates after the certificate validity period
- check that $CERT-RDMR token as specified in the CertDatum is spent
- check that the spent $CERT is also burned

Notes:
 - skips foreign inputs
 - can burn multiple $CERT tokens
-}
certMpBurn :: ClosedTerm (PScriptContext :--> POpaque)
certMpBurn = phoistAcyclic $
  plam $ \ctx -> ptrace "CertMp burn" P.do
    ctx' <- pletFields @'["txInfo", "purpose"] ctx
    ownCs <- plet $ pownCurrencySymbol # ctx'.purpose

    let foldFn shouldBurn txInInfo = P.do
          txIn <- plet $ pfield @"resolved" # txInInfo
          txInVal <- plet $ pfield @"value" # txIn
          pif
            (phasCurrency # ownCs # txInVal)
            ( ptrace "CertMp burn: Found own input" P.do
                certDatum' <- plet $ pdatumFromTxOut @PCertDatum # ctx # txIn
                certDatum <-
                  pletFields
                    @'[ "cert'id"
                      , "cert'validity"
                      , "cert'redeemerAc"
                      ]
                    $ certDatum'
                ptrace "CertMp burn: Parsed the CertDatum"

                certValidUntil <- plet $ pfield @"_0" #$ pfield @"to" # certDatum.cert'validity
                _ <- plet $ pmustValidateAfter # ctx # certValidUntil
                ptrace "CertMp burn: Can collect invalid cert"

                redeemerAc <- pletFields @'["_0", "_1"] certDatum.cert'redeemerAc
                -- TODO(perf): Consider adding a TxOutRef to the redeemer as it would make it more efficient to find the $CERT-RDMR input
                _ <- plet $ pmustSpendAtLeast # ctx # redeemerAc._0 # redeemerAc._1 # 1
                ptrace "CertMp burn: At least 1 $CERT-RDMR spent"

                certVal <- plet $ PValue.psingleton # ownCs # pcon (PTokenName $ certDatum.cert'id) # 1
                _ <-
                  plet $
                    pif
                      (pcurrencyValue # ownCs # txInVal #== certVal)
                      (ptrace "CertMp burn: Spent 1 $CERT token" punit)
                      (ptraceError "CertMp burn: Must spend a 1 $CERT token")

                shouldBurn <> inv certVal
            )
            (ptrace "CertMp burn: Skipping foreign input" shouldBurn)

    shouldBurn <- plet $ pfoldTxInputs # ctx # plam foldFn # mempty

    _ <- plet $ pmustMintCurrency # ctx # ownCs # shouldBurn

    ptrace "CertMp burn: All $CERTs spent and burned" $ popaque punit

{- | Validates minting of $CERT tokens

- check that the $AA quantity as specified in the CertMpParams is spent
- accumulate the $AA inputs into a unique token name to use for the $CERT token minted
- check that 1 $CERT is paid to @CertV
- check that the $CERT outputs at @CertV has a valid CertDatum.cert'id

Notes:
- can mint only 1 $CERT token per transaction
-}
certMpMint :: ClosedTerm (PCertMpParams :--> PScriptContext :--> POpaque)
certMpMint = phoistAcyclic $
  plam $ \params ctx -> ptrace "CertMp mint" P.do
    ctx' <- pletFields @'["txInfo", "purpose"] ctx
    ownCs <- plet $ pownCurrencySymbol # ctx'.purpose
    certParams <- pletFields @'["cmp'authAuthorityAc", "cmp'requiredAtLeastAaQ", "cmp'certVAddress"] params

    tnBytes <- plet $ pmustSpendAtLeastAa # ctx # certParams.cmp'authAuthorityAc # certParams.cmp'requiredAtLeastAaQ
    ptrace "CertMp mint: Spent at least a required quantity of $AA tokens"

    certTn <- plet $ pcon $ PTokenName tnBytes
    _ <- plet $ pmustMintCurrency # ctx # ownCs # (PValue.psingleton # ownCs # certTn # 1)
    ptrace "CertMp mint: Minted 1 $CERT"

    _ <-
      plet $
        pmustPayCurrencyWithDatumTo # ctx
          # ownCs
          # (PValue.psingleton # ownCs # certTn # 1)
          # plam (\(certDatum :: Term s PCertDatum) -> (pfield @"cert'id" # certDatum) #== tnBytes)
          # certParams.cmp'certVAddress
    ptrace "CertMp mint: Paid 1 $CERT to @CertV and attached a valid datum" $ popaque punit

-- | $AUTH minting policy
mkAuthMp :: ClosedTerm (PAsData PAuthMpParams :--> PMintingPolicy)
mkAuthMp = phoistAcyclic $
  plam $ \params red ctx -> ptrace "AuthMp" P.do
    red' <- plet $ pfromData (ptryFromData @PAuthMpRedeemer red)

    pmatch red' \case
      PAuthMpBurn _ -> authMpBurn # ctx
      PAuthMpMint _ -> authMpMint # pfromData params # ctx

{- | Validates minting of $AUTH tokens

- check that at least N $AA tokens are spent
- hash spent $AA inputs and create a unique token name for $AUTH token being minted
- check if >1 $AUTH tokens with the same unique token name have been minted (exclusively)
-}
authMpMint :: ClosedTerm (PAuthMpParams :--> PScriptContext :--> POpaque)
authMpMint = phoistAcyclic $
  plam $ \params ctx -> ptrace "AuthMp mint" P.do
    ctx' <- pletFields @'["txInfo", "purpose"] ctx
    ownCs <- plet $ pownCurrencySymbol # ctx'.purpose
    minted <- plet $ pfield @"mint" # ctx'.txInfo
    authMpParams <- pletFields @'["amp'authAuthorityAc", "amp'requiredAtLeastAaQ", "amp'certVAddress"] params

    authId <- plet $ pmustSpendAtLeastAa # ctx # authMpParams.amp'authAuthorityAc # authMpParams.amp'requiredAtLeastAaQ
    ptrace "AuthMp mint: Spent at least a required quantity of $AA tokens"

    pif
      (0 #< (pcurrencyTokenQuantity # ownCs # pcon (PTokenName authId) # minted))
      (ptrace "AuthMp mint: At least one $AUTH token is minted" $ popaque punit)
      (ptraceError "AuthMp mint: Must mint at least one $AUTH token")

{- | Validates burning of $AUTH tokens

- accumulate all spent $AUTH tokens and check if all are burned

Notes:
- $AUTH tokens can be burned freely
-}
authMpBurn :: ClosedTerm (PScriptContext :--> POpaque)
authMpBurn = phoistAcyclic $
  plam $ \ctx -> ptrace "AuthMp burn $AUTH" P.do
    ctx' <- pletFields @'["txInfo", "purpose"] ctx
    ownCs <- plet $ pownCurrencySymbol # ctx'.purpose

    let foldFn shouldBurn txInInfo = P.do
          txIn <- plet $ pfield @"resolved" # txInInfo
          txInVal <- plet $ pfield @"value" # txIn
          pif
            (phasCurrency # ownCs # txInVal)
            ( ptrace "AuthMp burn $AUTH: Found own input" P.do
                ownSpent <- plet $ pcurrencyValue # ownCs # txInVal
                shouldBurn <> inv ownSpent
            )
            (ptrace "AuthMp burn $AUTH: Skipping foreign input" shouldBurn)

    shouldBurn <- plet $ pfoldTxInputs # ctx # plam foldFn # mempty

    _ <- plet $ pmustMintCurrency # ctx # ownCs # shouldBurn

    ptrace "AuthMp burn: Burned all spent $AUTH tokens" $ popaque punit

{- | Checks for total spent $AA tokens and create a unique bytestring from them

- accumulate all spent $AA tokens and check if totals are at least as specified
- create unique bytestring from $AA inputs by hashing the concatenation of (idx,id) pairs
-}
pmustSpendAtLeastAa :: ClosedTerm (PScriptContext :--> PTuple PCurrencySymbol PTokenName :--> PInteger :--> PByteString)
pmustSpendAtLeastAa = phoistAcyclic $
  plam $ \ctx aaAc atLeastAaQ -> ptrace "pmustSpendAtLeastAa" P.do
    aaCs <- plet $ pfield @"_0" # aaAc
    aaTn <- plet $ pfield @"_1" # aaAc

    let foldFn acc txIn = P.do
          -- check if $AA input
          txIn' <- pletFields @'["resolved", "outRef"] txIn
          txInVal <- plet $ pfield @"value" # txIn'.resolved
          pif
            (phasCurrency # aaCs # txInVal)
            ( ptrace "pmustSpendAtLeastAa: Found an $AA input" P.do
                PPair aaVal tnBytes <- pmatch acc
                -- accumulate token name bytes
                txId <- plet $ pfield @"_0" #$ pfield @"id" # txIn'.outRef
                txIdx <- plet $ pfield @"idx" # txIn'.outRef
                tnBytes' <- plet $ tnBytes <> pconsBS # txIdx # txId
                -- accumulate token quantities
                aaVal' <- plet $ aaVal #+ (pvalueOf # txInVal # aaCs # aaTn)

                pcon $ PPair aaVal' tnBytes'
            )
            (ptrace "pmustSpendAtLeastAa: Skipping non $AA input" acc)

    PPair aaTokensSpent tnBytes <- pmatch $ pfoldTxInputs # ctx # plam foldFn # pcon (PPair 0 mempty)

    pif
      (atLeastAaQ #<= aaTokensSpent)
      (ptrace "pmustSpendAtLeastAa: Spent at least the specified amount of AA tokens" $ pblake2b_256 # tnBytes)
      (ptraceError "pmustSpendAtLeastAa: Must spend at least the specified amount of AA tokens")
