{-# LANGUAGE ScopedTypeVariables #-}
module Hercules.Agent.Config where

import           Protolude               hiding ( to )
import qualified System.Environment
import           Toml
import           Hercules.Agent.Json           as Json

data ConfigPath = TomlPath FilePath
                | JsonPath FilePath

data Config = Config
  { herculesApiBaseURL :: Maybe Text
  , clusterJoinTokenPath :: Text
  , concurrentTasks :: Integer
  , cacheKeysPath :: Maybe Text
  } deriving (Generic)

tomlCodec :: TomlCodec Config
tomlCodec =
  Config
    <$> dioptional (Toml.text "apiBaseUrl")
    .= herculesApiBaseURL
    <*> Toml.text "clusterJoinTokenPath"
    .= clusterJoinTokenPath
    <*> Toml.integer "concurrentTasks"
    .= concurrentTasks
    <*> dioptional (Toml.text "cacheKeysPath")
    .= cacheKeysPath

jsonCodec :: JsonCodec Config
jsonCodec =
  Config
    <$> dioptional (Json.text "apiBaseUrl")
    .= herculesApiBaseURL
    <*> Json.text "clusterJoinTokenPath"
    .= clusterJoinTokenPath
    <*> Json.integer "concurrentTasks"
    .= concurrentTasks
    <*> (dioptional (Json.text "cacheKeysPath"))
    .= cacheKeysPath


defaultConfig :: Config
defaultConfig = Config
  { herculesApiBaseURL = Nothing
  , clusterJoinTokenPath = panic "Config.clusterJoinTokenPath wasn't set." -- TODO optional?
  , concurrentTasks = 4
  , cacheKeysPath = Nothing
  }

determineDefaultApiBaseUrl :: IO Text
determineDefaultApiBaseUrl = do
  maybeEnv <- System.Environment.lookupEnv "HERCULES_API_BASE_URL"
  pure $ maybe defaultApiBaseUrl toS maybeEnv

defaultApiBaseUrl :: Text
defaultApiBaseUrl = "https://hercules-ci.com"

readConfig :: ConfigPath -> IO Config
readConfig loc = case loc of
  TomlPath fp -> Toml.decodeFile tomlCodec (toSL fp)
  JsonPath fp -> Json.decodeFile jsonCodec (toSL fp)
