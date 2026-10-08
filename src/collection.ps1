# The category a failure is recorded under.
function Get-Hotpl8FailureCode($ErrorRecord) {
    # Exception messages may include paths or native output. Export only known categories.
    $exception=$ErrorRecord.Exception
    while($exception){
        if($exception -is [UnauthorizedAccessException]){return 'access_denied'}
        if($exception -is [IO.IOException]){return 'state_io_failed'}
        $exception=$exception.InnerException
    }
    switch -Regex ([string]$ErrorRecord.FullyQualifiedErrorId) {
        'PropertyAssignment|PropertyNotFound' {return 'invalid_cached_shape'}
        'ParameterBinding' {return 'invalid_parameter'}
        'UnauthorizedAccess|PermissionDenied' {return 'access_denied'}
        'IOException' {return 'state_io_failed'}
        default {return 'unexpected_collection_error'}
    }
}
