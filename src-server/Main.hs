{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE TemplateHaskell           #-}

module Main where

import Aws.Lambda

import Handler.GetSession

-- ========================================= Main ========================================
generateLambdaDispatcher
