# Thin terminal client of the same durable operation used by local agents.
function Show-Hotpl8Onboarding([string]$Directory,[string]$Provider,[switch]$NewAccount,[switch]$AllowInstall) {
    $r=Invoke-Hotpl8Onboarding $Directory begin '' $Provider '' -NewAccount:$NewAccount -AllowInstall:$AllowInstall
    $last='';$opened='';$retries=0
    'Connect an account to HotPl8. Your existing sign-ins stay in place.'
    try{
        while($true){
            if($r.message -ne $last){$r.message;$last=$r.message}
            switch($r.phase){
                'needs_provider'{
                    $answer=Read-Host '1 Claude / 2 ChatGPT (Codex) / Enter to finish later'
                    if(-not $answer){return}
                    $providerChoice=switch($answer){'1'{'claude'};'2'{'codex'};'claude'{'claude'};'codex'{'codex'}}
                    if(-not $providerChoice){continue}
                    $r=Invoke-Hotpl8Onboarding $Directory choose_provider $r.operationId $providerChoice;continue
                }
                'needs_account_choice'{
                    for($i=0;$i -lt $r.candidates.Count;$i++){[string]($i+1)+'. '+(ConvertTo-Hotpl8SafeText $r.candidates[$i].label)}
                    $answer=Read-Host 'Account number, N for another sign-in, or Enter to finish later'
                    if(-not $answer){return}
                    if($answer -eq 'n'){$r=Invoke-Hotpl8Onboarding $Directory sign_in $r.operationId;continue}
                    $number=0
                    if([int]::TryParse($answer,[ref]$number) -and $number -gt 0 -and $number -le $r.candidates.Count){$r=Invoke-Hotpl8Onboarding $Directory choose_account $r.operationId '' $r.candidates[$number-1].id}
                    continue
                }
                'needs_install_authorization'{
                    $answer=Read-Host 'Install these required tools for your user account? [Y/n]'
                    if($answer -and $answer -ne 'y'){return}
                    $r=Invoke-Hotpl8Onboarding $Directory install $r.operationId -AllowInstall;continue
                }
                'needs_sign_in'{
                    $r=Invoke-Hotpl8Onboarding $Directory sign_in $r.operationId;continue
                }
                'awaiting_sign_in'{
                    if($r.handoff.url -and $opened -ne $r.handoff.url){
                        $opened=$r.handoff.url
                        # Opened from this foreground terminal so the page comes to the front.
                        'Sign in here: '+$opened
                        if($r.handoff.code){'Provider code: '+$r.handoff.code}
                        try{if($env:OS -eq 'Windows_NT'){Start-Process $opened|Out-Null}else{& /usr/bin/open $opened}}catch{'Open the link above in your browser.'}
                        if($r.handoff.kind -eq 'paste_code' -and 'submit_code' -in $r.nextActions -and -not [Console]::IsInputRedirected){'After signing in, copy the code the page shows, paste it here, and press Enter.'}
                    }
                    if('submit_code' -in $r.nextActions -and -not [Console]::IsInputRedirected){
                        # Nothing finishes without the code, so a plain visible line read is safe
                        # and keeps the terminal's own paste. Enter alone rechecks progress.
                        $entered=(Read-Host 'Code') -replace '\x1b?\[20[01]~',''
                        if($entered.Trim()){
                            try{$r=Invoke-Hotpl8Onboarding $Directory submit_code $r.operationId -Code $entered}catch{$_.Exception.Message}
                            continue
                        }
                        $r=Invoke-Hotpl8Onboarding $Directory status $r.operationId;continue
                    }
                }
                'already_connected'{
                    'Your browser used an account already in HotPl8. Choose another browser profile or a guest window for the next link.'
                    $answer=Read-Host 'Sign into a different account? [Y/n]'
                    if($answer -and $answer -ne 'y'){return}
                    $r=Invoke-Hotpl8Onboarding $Directory sign_in $r.operationId;continue
                }
                'ready'{
                    'Setup complete. Opening your account view.'
                    . (Join-Path $PSScriptRoot 'dashboard.ps1')
                    Show-Hotpl8Dashboard $Directory
                    return
                }
                'pending'{
                    if($retries -lt 2){
                        $retries++;'Retrying automatically. You can close setup and return later.'
                        Start-Sleep -Seconds 5
                        $r=Invoke-Hotpl8Onboarding $Directory retry $r.operationId;continue
                    }
                    $answer=Read-Host 'Press Enter to try again, or L to finish later'
                    if($answer -eq 'l'){return}
                    $r=Invoke-Hotpl8Onboarding $Directory retry $r.operationId;continue
                }
                'failed'{return}
                'canceled'{return}
            }
            Start-Sleep -Seconds 2
            $r=Invoke-Hotpl8Onboarding $Directory status $r.operationId
        }
    }finally{
        # Exiting the UI does not abandon a completed sign-in or kill another client's work.
        if($r.phase -notin @('ready','canceled')){'Your progress is saved. Run hotpl8 '+$(if($NewAccount){'add'}else{'setup'})+' to continue.'}
    }
}
