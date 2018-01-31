{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import qualified Language.Oberon.Grammar as Grammar

import Control.Monad
import Data.Data (Data)
import Data.Functor.Compose (getCompose)
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Text.IO (getLine, readFile)
import Data.Typeable (Typeable)
import Options.Applicative
import Text.Grampa (parseComplete)
--import Language.Oberon.PrettyPrinter (LPretty(..), displayS, renderPretty)
import ReprTree

import Prelude hiding (getLine, readFile)

data GrammarMode = ModuleMode | StatementMode | ExpressionMode
    deriving Show

data Opts = Opts
    { optsInteractive :: GrammarMode
    , optsIndex       :: Int
    , optsPretty      :: Bool
    , optsFile        :: Maybe FilePath
    } deriving Show

main :: IO ()
main = execParser opts >>= main'
  where
    opts = info (helper <*> p)
        ( fullDesc
       <> progDesc "Parse an Oberon file, or parse interactively"
       <> header "Oberon parser")

    p :: Parser Opts
    p = Opts
        <$> (mode <|> pure ExpressionMode)
        <*> (option auto (long "index" <> help "Index of ambiguous parse" <> showDefault <> value 0 <> metavar "INT"))
        <*> switch
            ( long "pretty"
              <> help "Pretty-print output")
        <*> optional (strArgument
            ( metavar "FILE"
              <> help "Oberon file to parse"))

    mode :: Parser GrammarMode
    mode = ModuleMode      <$ switch (long "module")
       <|> StatementMode  <$ switch (long "statement")
       <|> ExpressionMode <$ switch (long "expression")

main' :: Opts -> IO ()
main' Opts{..} =
    case optsFile of
        Just file -> readFile file >>= go Grammar.module_prod file
        Nothing ->
            case optsInteractive of
                ModuleMode      -> forever $ getLine >>= go Grammar.module_prod "<stdin>"
                StatementMode  -> forever $ getLine >>= go Grammar.statement "<stdin>"
                ExpressionMode -> forever $ getLine >>= go Grammar.expression "<stdin>"
  where
    go :: (Show f, Data f) => 
          (forall x. Grammar.OberonGrammar x -> x f) -> String -> Text -> IO ()
    go f filename contents = case getCompose (f $ parseComplete Grammar.oberonGrammar contents)
                             of Right [x] -> succeed x
                                Right l -> putStrLn ("Ambiguous: " ++ show optsIndex ++ "/" ++ show (length l) ++ " parses") >> succeed (l !! optsIndex)
                                Left err -> error (show err)
    succeed x = if optsPretty
                then putStrLn (reprTreeString x)
                else print x
