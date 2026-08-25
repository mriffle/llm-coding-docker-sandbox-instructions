# PSScriptAnalyzer settings for the installers.
#
# These are standalone user-facing scripts, not a module, so a few of the
# module-authoring rules do not apply:
#
#   PSAvoidUsingWriteHost      an installer's whole job is talking to a person
#   PSUseSingularNouns         Get-AgentBuildArgs really does return several
#   PSUseShouldProcess         -WhatIf on an installer's helpers is noise;
#                              the destructive path already prompts
#   PSUseBOMForUnicodeEncoded  the files are UTF-8 without BOM on purpose
#   PSReviewUnusedParameter    false positive: the param() switches are read
#                              inside Invoke-Main, which the analyser cannot see
@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseSingularNouns',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseBOMForUnicodeEncodedFile',
        'PSReviewUnusedParameter'
    )
}
