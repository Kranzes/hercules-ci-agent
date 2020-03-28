{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- This implements an optimized routine to build from a remote derivation.
-- It is not in the "CNix" tree because it seems to be too specific for general use.
-- BuildStatus and BuildResult *can* be moved there, but I do not know of an
-- easy to maintain approach to do decouple it with inline-c-cpp. Perhaps it's
-- better to use an FFI generator instead?

module Hercules.Agent.Worker.Build.Prefetched where

import CNix
import CNix.Internal.Context
import qualified Data.ByteString.Char8 as C8
import Foreign (alloca, peek)
import Foreign.C (peekCString)
import qualified Language.C.Inline.Cpp as C
import qualified Language.C.Inline.Cpp.Exceptions as C
import Protolude

C.context context

C.include "<cstring>"

C.include "<nix/config.h>"

C.include "<nix/shared.hh>"

C.include "<nix/store-api.hh>"

C.include "<nix/get-drvs.hh>"

C.include "<nix/derivations.hh>"

C.include "<nix/affinity.hh>"

C.include "<nix/globals.hh>"

C.include "<nix/fs-accessor.hh>"

C.include "aliases.h"

C.using "namespace nix"

data BuildStatus
  = Built
  | Substituted
  | AlreadyValid
  | PermanentFailure
  | InputRejected
  | OutputRejected
  | TransientFailure -- possibly transient
  | CachedFailure -- no longer used
  | TimedOut
  | MiscFailure
  | DependencyFailed
  | LogLimitExceeded
  | NotDeterministic
  | Successful -- Catch-all for unknown successful status
  | UnknownFailure -- Catch-all for unknown unsuccessful status
  deriving (Show)

-- Must match the FFI boilerplate
toBuildStatus :: C.CInt -> BuildStatus
toBuildStatus 0 = Built
toBuildStatus 1 = Substituted
toBuildStatus 2 = AlreadyValid
toBuildStatus 3 = PermanentFailure
toBuildStatus 4 = InputRejected
toBuildStatus 5 = OutputRejected
toBuildStatus 6 = TransientFailure
toBuildStatus 7 = CachedFailure
toBuildStatus 8 = TimedOut
toBuildStatus 9 = MiscFailure
toBuildStatus 10 = DependencyFailed
toBuildStatus 11 = LogLimitExceeded
toBuildStatus 12 = NotDeterministic
toBuildStatus (-1) = Successful
toBuildStatus _ = UnknownFailure

data BuildResult
  = BuildResult
      { isSuccess :: Bool,
        status :: BuildStatus,
        startTime :: C.CTime,
        stopTime :: C.CTime,
        errorMessage :: Text
      }
  deriving (Show)

-- | @buildDerivation derivationPath derivationText@
buildDerivation :: Ptr (Ref NixStore) -> ByteString -> [ByteString] -> IO BuildResult
buildDerivation store derivationPath extraInputs =
  let extraInputsMerged = C8.intercalate "\n" extraInputs
   in alloca $ \successPtr ->
        alloca $ \statusPtr ->
          alloca $ \startTimePtr ->
            alloca $ \stopTimePtr ->
              alloca $ \errorMessagePtr -> do
                [C.throwBlock| void {
      Store &store = **$(refStore* store);
      bool &success = *$(bool *successPtr);
      int &status = *$(int *statusPtr);
      const char *&errorMessage = *$(const char **errorMessagePtr);
      time_t &startTime = *$(time_t *startTimePtr);
      time_t &stopTime = *$(time_t *stopTimePtr);
      std::string derivationPath($bs-ptr:derivationPath, $bs-len:derivationPath);
      std::string extraInputsMerged($bs-ptr:extraInputsMerged, $bs-len:extraInputsMerged);
      std::list<nix::ref<nix::Store>> stores = getDefaultSubstituters();
      stores.push_front(*$(refStore* store));
      stores.push_back(openStore("https://hercules-ci.cachix.org"));

      std::unique_ptr<nix::Derivation> derivation(nullptr);

      for (nix::ref<nix::Store> & currentStore : stores) {
        try {
          auto accessor = currentStore->getFSAccessor();
          auto drvText = accessor->readFile(derivationPath);

          Path tmpDir = createTempDir();
          AutoDelete delTmpDir(tmpDir, true);
          Path drvTmpPath = tmpDir + "/drv";
          writeFile(drvTmpPath, drvText, 0600);
          derivation = make_unique<nix::Derivation>(nix::readDerivation(drvTmpPath));
          break;
        } catch (nix::Interrupted &e) {
          throw e;
        } catch (nix::Error &e) {
          printTalkative("ignoring exception during drv lookup in %s: %s", currentStore->getUri(), e.what());
        } catch (std::exception &e) {
          printTalkative("ignoring exception during drv lookup in %s: %s", currentStore->getUri(), e.what());
        }
      }

      if (!derivation) {
        throw nix::Error(format("Could not read derivation %1% from local store or substituters.") % derivationPath);
      }

      {
        std::string extraInput;
        std::istringstream stream(extraInputsMerged);
        while (std::getline(stream, extraInput)) {
          derivation->inputSrcs.insert(extraInput);
        }
      }

      // TODO: fall back to untrusted buildDerivation
      nix::BuildResult result = store.buildDerivation(derivationPath, *derivation);
      switch (result.status) {
        case nix::BuildResult::Built:
          status = 0;
          break;
        case nix::BuildResult::Substituted:
          status = 1;
          break;
        case nix::BuildResult::AlreadyValid:
          status = 2;
          break;
        case nix::BuildResult::PermanentFailure:
          status = 3;
          break;
        case nix::BuildResult::InputRejected:
          status = 4;
          break;
        case nix::BuildResult::OutputRejected:
          status = 5;
          break;
        case nix::BuildResult::TransientFailure: // possibly transient
          status = 6;
          break;
        case nix::BuildResult::CachedFailure: // no longer used
          status = 7;
          break;
        case nix::BuildResult::TimedOut:
          status = 8;
          break;
        case nix::BuildResult::MiscFailure:
          status = 9;
          break;
        case nix::BuildResult::DependencyFailed:
          status = 10;
          break;
        case nix::BuildResult::LogLimitExceeded:
          status = 11;
          break;
        case nix::BuildResult::NotDeterministic:
          status = 12;
          break;
        default:
          status = result.success() ? -1 : -2;
          break;
      }
      success = result.success();
      errorMessage = strdup(result.errorMsg.c_str());
      startTime = result.startTime;
      stopTime = result.stopTime;
    }
    |]
                successValue <- peek successPtr
                statusValue <- peek statusPtr
                startTimeValue <- peek startTimePtr
                stopTimeValue <- peek stopTimePtr
                errorMessageValue0 <- peek errorMessagePtr
                errorMessageValue <- peekCString errorMessageValue0
                pure $ BuildResult
                  { isSuccess = successValue /= 0,
                    status = toBuildStatus statusValue,
                    startTime = startTimeValue,
                    stopTime = stopTimeValue,
                    errorMessage = toS errorMessageValue
                  }
