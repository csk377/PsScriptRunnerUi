@{
    IncludeRules = @(
        'PSAlignAssignmentStatement'
        'PSAvoidTrailingWhitespace'
        'PSPlaceCloseBrace'
        'PSPlaceOpenBrace'
        'PSUseConsistentIndentation'
        'PSUseConsistentWhitespace'
    )

    Rules        = @{
        PSAlignAssignmentStatement = @{
            Enable         = $true
            CheckHashtable = $true
        }

        PSAvoidTrailingWhitespace  = @{
            Enable = $true
        }

        PSPlaceCloseBrace          = @{
            Enable             = $true
            IgnoreOneLineBlock = $true
            NewLineAfter       = $true
            NoEmptyLineBefore  = $false
        }

        PSPlaceOpenBrace           = @{
            Enable             = $true
            IgnoreOneLineBlock = $true
            NewLineAfter       = $true
            OnSameLine         = $true
        }

        PSUseConsistentIndentation = @{
            Enable              = $true
            IndentationSize     = 4
            Kind                = 'space'
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }

        PSUseConsistentWhitespace  = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckParameter                          = $false
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $false
            CheckSeparator                          = $true
            IgnoreAssignmentOperatorInsideHashTable = $true
        }
    }
}
