# Screen-EmailTemplates.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Email messages (Settings)
# Screen version: 2.9.0   (changes ONLY when this screen changes - not with every release)

# The default wording lives in this file (below). What you change on the screen is saved in email-templates.json next to the tool,
# and the tool reads it every time it sends an e-mail - so a change is used at once, and "Reset to default" brings the original back.
# Arabic is kept as HTML character codes (&#1605;) so this file and the saved file stay plain ASCII; the screen shows and edits real Arabic letters.
# Placeholders like {first} are replaced when the e-mail is sent. A text is HTML: <b>bold</b>, <a href="...">link</a>.

# WHAT THIS SCREEN DOES: Settings > Email messages. Lets an administrator edit the wording (English + Arabic), subject, layout, logo picture
# or a full custom HTML for every e-mail the tool sends (password reset AD / temporary password / Temporary Access Pass, MFA re-setup, guest invitation,
# shared / normal mailbox notices), preview it, and reset it to the default. Other screens call New-PwMailHtml, New-GuestMailHtml and New-MbxMailHtml here to build the real e-mails.
# ENDPOINTS: /api/email-tpl-list, -save, -reset, -preview, /api/email-custom-save, /api/email-img-save, /api/email-img-remove.
# DATA: email-templates.json (only what differs from the default), the email-images folder, and the mail settings file ($script:MailCfgFile via Get-MailCfg)
# for the subjects of the password e-mails. Microsoft Graph: only Get-MgUser (to read a person's name from your tenant). No AD / Exchange calls.
# PERMISSION: no check in this file; the server only lets signed-in portal users reach these handlers.
#
# Where the saved changes live. Keys inside: '<store>' (text blocks), 'subject.<id>', 'layout.<id>', 'custom.<id>'.
$script:EmailTplFile = Join-Path $Root 'email-templates.json'
# All e-mail definitions (default wording), filled by the New-EmailDef / Add-EmailBlock lines below.
$script:EmailDefs = [ordered]@{}
$script:EmailPreview = $null        # set only while the preview is being built (the unsaved texts typed on the screen)
# Cache of email-templates.json together with its file time, so the file is only re-read when it changed.
$script:EmailStoreCache = $null; $script:EmailStoreStamp = -1

# Registers one e-mail type: id, title and description for the screen, default subject, the {placeholders} it supports ('name|meaning'),
# the preview variants (checkboxes) and a note. Its text blocks are added next with Add-EmailBlock.
function New-EmailDef($id, $title, $desc, $subject, $vars, $variants, $note) {
    $script:EmailDefs[$id] = @{ id = $id; title = $title; desc = $desc; subject = $subject; vars = @($vars); variants = @($variants); note = $note; blocks = [ordered]@{} }
}
# Adds one editable text block to an e-mail: key, label, kind ('html' = one paragraph, 'list' = one bullet per line), English and Arabic default text,
# $store = the name it is saved under (blocks with the same store name are shared between e-mails), and $enOnly = no Arabic version.
function Add-EmailBlock($id, $k, $label, $kind, $en, $ar, $store, $note, $enOnly) {
    $script:EmailDefs[$id].blocks[$k] = @{ k = $k; label = $label; kind = $kind; en = $en; ar = $ar; store = $(if ($store) { $store } else { "$id.$k" }); note = $note; enOnly = [bool]$enOnly }
}

# From here to the next section: the built-in wording. Arabic text is written as HTML codes (&#NNNN;) so this file stays plain ASCII.
# ---- the default wording (the original e-mails) ----
New-EmailDef 'ad' 'Password reset - on-premises AD' 'Sent after you reset an on-premises Active Directory password. The password itself is always shown in a box under the label.' 'Your new password' @('first|First name (taken from the person''s account in your tenant)','last|Last name (same place)','full|First and last name together','greet|The name chosen in Name in the greeting (default: first name)','name|Full name of the person','upn|Account name (sign-in name)','signature|Your signature (set in Email settings)','change_link|Link to change the password','mfa_link|Link to set up Microsoft Authenticator','sspr_link|Link to reset the password yourself') @('pwOnce|One-time password (must change at first sign-in)') 'Sent from the Cloud password and On-premises AD screens. Subject is the same one as in Email settings.'
Add-EmailBlock 'ad' 'hello' 'Greeting' 'html' 'Hello {greet},' '&#1605;&#1585;&#1581;&#1576;&#1611;&#1575; {greet}&#1548;' '' '' $false
Add-EmailBlock 'ad' 'intro' 'What happened' 'html' 'The password of your university account <b>{upn}</b> has been reset by {signature}.' '&#1578;&#1605;&#1578; &#1573;&#1593;&#1575;&#1583;&#1577; &#1578;&#1593;&#1610;&#1610;&#1606; &#1603;&#1604;&#1605;&#1577; &#1605;&#1585;&#1608;&#1585; &#1581;&#1587;&#1575;&#1576;&#1603; &#1575;&#1604;&#1580;&#1575;&#1605;&#1593;&#1610; <b><bdi>{upn}</bdi></b> &#1605;&#1606; &#1602;&#1616;&#1576;&#1604; {signature}.' '' '' $false
Add-EmailBlock 'ad' 'label' 'Label above the password' 'html' 'Your password:' '&#1603;&#1604;&#1605;&#1577; &#1575;&#1604;&#1605;&#1585;&#1608;&#1585; &#1575;&#1604;&#1582;&#1575;&#1589;&#1577; &#1576;&#1603;:' '' '' $false
Add-EmailBlock 'ad' 'once' 'Note - one-time password' 'html' '<b>This is a one-time password.</b> You must change it the first time you sign in - you will be asked to choose a new password.' '<b>&#1607;&#1584;&#1607; &#1603;&#1604;&#1605;&#1577; &#1605;&#1585;&#1608;&#1585; &#1604;&#1605;&#1585;&#1577; &#1608;&#1575;&#1581;&#1583;&#1577;.</b> &#1610;&#1580;&#1576; &#1593;&#1604;&#1610;&#1603; &#1578;&#1594;&#1610;&#1610;&#1585;&#1607;&#1575; &#1593;&#1606;&#1583; &#1578;&#1587;&#1580;&#1610;&#1604; &#1575;&#1604;&#1583;&#1582;&#1608;&#1604; &#1604;&#1571;&#1608;&#1604; &#1605;&#1585;&#1577; - &#1587;&#1610;&#1615;&#1591;&#1604;&#1576; &#1605;&#1606;&#1603; &#1575;&#1582;&#1578;&#1610;&#1575;&#1585; &#1603;&#1604;&#1605;&#1577; &#1605;&#1585;&#1608;&#1585; &#1580;&#1583;&#1610;&#1583;&#1577;.' '' '' $false
Add-EmailBlock 'ad' 'normal' 'Note - normal password' 'html' '<b>This is your password.</b> If you want to change it, go to {change_link}.' '<b>&#1607;&#1584;&#1607; &#1603;&#1604;&#1605;&#1577; &#1575;&#1604;&#1605;&#1585;&#1608;&#1585; &#1575;&#1604;&#1582;&#1575;&#1589;&#1577; &#1576;&#1603;.</b> &#1573;&#1584;&#1575; &#1603;&#1606;&#1578; &#1578;&#1585;&#1594;&#1576; &#1601;&#1610; &#1578;&#1594;&#1610;&#1610;&#1585;&#1607;&#1575;&#1548; &#1575;&#1606;&#1578;&#1602;&#1604; &#1573;&#1604;&#1609; {change_link}.' '' '' $false
Add-EmailBlock 'ad' 'advice' 'Advice - Microsoft Authenticator' 'html' '<b>Recommended: Microsoft Authenticator.</b> Set up the Microsoft Authenticator app on your phone at {mfa_link}. Then, in the future, you can reset your password yourself at {sspr_link} - without contacting IT support.' '<b>&#1610;&#1615;&#1606;&#1589;&#1581; &#1576;&#1575;&#1587;&#1578;&#1582;&#1583;&#1575;&#1605; &#1578;&#1591;&#1576;&#1610;&#1602; Microsoft Authenticator.</b> &#1602;&#1605; &#1576;&#1573;&#1593;&#1583;&#1575;&#1583; &#1578;&#1591;&#1576;&#1610;&#1602; Microsoft Authenticator &#1593;&#1604;&#1609; &#1607;&#1575;&#1578;&#1601;&#1603; &#1605;&#1606; &#1582;&#1604;&#1575;&#1604; {mfa_link}. &#1576;&#1593;&#1583; &#1584;&#1604;&#1603; &#1610;&#1605;&#1603;&#1606;&#1603; &#1605;&#1587;&#1578;&#1602;&#1576;&#1604;&#1611;&#1575; &#1573;&#1593;&#1575;&#1583;&#1577; &#1578;&#1593;&#1610;&#1610;&#1606; &#1603;&#1604;&#1605;&#1577; &#1575;&#1604;&#1605;&#1585;&#1608;&#1585; &#1576;&#1606;&#1601;&#1587;&#1603; &#1605;&#1606; &#1582;&#1604;&#1575;&#1604; {sspr_link} &#1583;&#1608;&#1606; &#1575;&#1604;&#1581;&#1575;&#1580;&#1577; &#1573;&#1604;&#1609; &#1575;&#1604;&#1578;&#1608;&#1575;&#1589;&#1604; &#1605;&#1593; &#1575;&#1604;&#1583;&#1593;&#1605; &#1575;&#1604;&#1601;&#1606;&#1610;.' '' '' $false
Add-EmailBlock 'ad' 'footer' 'Security notice at the bottom' 'html' 'If you did not ask for this, contact IT support straight away. IT will never ask you to reply with your password.' '&#1573;&#1584;&#1575; &#1604;&#1605; &#1578;&#1591;&#1604;&#1576; &#1584;&#1604;&#1603;&#1548; &#1578;&#1608;&#1575;&#1589;&#1604; &#1605;&#1593; &#1575;&#1604;&#1583;&#1593;&#1605; &#1575;&#1604;&#1601;&#1606;&#1610; &#1601;&#1608;&#1585;&#1611;&#1575;. &#1604;&#1606; &#1610;&#1591;&#1604;&#1576; &#1605;&#1606;&#1603; &#1575;&#1604;&#1583;&#1593;&#1605; &#1575;&#1604;&#1601;&#1606;&#1610; &#1571;&#1576;&#1583;&#1611;&#1575; &#1575;&#1604;&#1585;&#1583; &#1576;&#1603;&#1604;&#1605;&#1577; &#1575;&#1604;&#1605;&#1585;&#1608;&#1585; &#1575;&#1604;&#1582;&#1575;&#1589;&#1577; &#1576;&#1603;.' 'pw.footer' 'Shared with the other password e-mails.' $false
New-EmailDef 'tap' 'Temporary Access Pass' 'Sent with a Temporary Access Pass for a cloud (Microsoft Entra) account. The pass is always shown in a box under the label.' 'Your university account password' @('first|First name (taken from the person''s account in your tenant)','last|Last name (same place)','full|First and last name together','greet|The name chosen in Name in the greeting (default: first name)','name|Full name of the person','upn|Account name (sign-in name)','signature|Your signature (set in Email settings)','within|How long the pass lasts','deadline|Date and time the pass stops working','once|The "single use" sentence (only when the pass is single use)','tap_link|Link to aka.ms/mysecurityinfo') @('once|Single-use pass') 'Subject is the Temporary Access Pass subject in Email settings.'
Add-EmailBlock 'tap' 'hello' 'Greeting' 'html' 'Hello {greet},' '&#1605;&#1585;&#1581;&#1576;&#1611;&#1575; {greet}&#1548;' '' '' $false
Add-EmailBlock 'tap' 'intro' 'What happened' 'html' 'A <b>Temporary Access Pass</b> has been created for your university account <b>{upn}</b>. You must use it to sign in and <b>change your password</b>.' '&#1578;&#1605; &#1573;&#1606;&#1588;&#1575;&#1569; &#1585;&#1605;&#1586; &#1608;&#1589;&#1608;&#1604; &#1605;&#1572;&#1602;&#1578; (Temporary Access Pass) &#1604;&#1581;&#1587;&#1575;&#1576;&#1603; &#1575;&#1604;&#1580;&#1575;&#1605;&#1593;&#1610; <b><bdi>{upn}</bdi></b>. &#1610;&#1580;&#1576; &#1593;&#1604;&#1610;&#1603; &#1575;&#1587;&#1578;&#1582;&#1583;&#1575;&#1605;&#1607; &#1604;&#1578;&#1587;&#1580;&#1610;&#1604; &#1575;&#1604;&#1583;&#1582;&#1608;&#1604; &#1579;&#1605; <b>&#1578;&#1594;&#1610;&#1610;&#1585; &#1603;&#1604;&#1605;&#1577; &#1575;&#1604;&#1605;&#1585;&#1608;&#1585;</b>.' '' '' $false
Add-EmailBlock 'tap' 'label' 'Label above the pass' 'html' 'Your Temporary Access Pass:' '&#1585;&#1605;&#1586; &#1575;&#1604;&#1608;&#1589;&#1608;&#1604; &#1575;&#1604;&#1605;&#1572;&#1602;&#1578; &#1575;&#1604;&#1582;&#1575;&#1589; &#1576;&#1603;:' '' '' $false
Add-EmailBlock 'tap' 'deadline' 'Deadline note' 'html' '<b>This is mandatory within {within}</b> - before <b>{deadline}</b>. After that the pass stops working{once}.' '<b>&#1607;&#1584;&#1575; &#1573;&#1604;&#1586;&#1575;&#1605;&#1610; &#1582;&#1604;&#1575;&#1604; {within}</b> - &#1602;&#1576;&#1604; <b><bdi>{deadline}</bdi></b>. &#1576;&#1593;&#1583; &#1584;&#1604;&#1603; &#1610;&#1578;&#1608;&#1602;&#1601; &#1575;&#1604;&#1585;&#1605;&#1586; &#1593;&#1606; &#1575;&#1604;&#1593;&#1605;&#1604;{once}.' '' '' $false
Add-EmailBlock 'tap' 'once' 'Single-use sentence (added to the deadline note)' 'html' ', and it can be used only once' '&#1548; &#1608;&#1610;&#1605;&#1603;&#1606; &#1575;&#1587;&#1578;&#1582;&#1583;&#1575;&#1605;&#1607; &#1605;&#1585;&#1577; &#1608;&#1575;&#1581;&#1583;&#1577; &#1601;&#1602;&#1591;' '' '' $false
Add-EmailBlock 'tap' 'stepsTitle' 'Title of the steps' 'html' 'What to do:' '&#1575;&#1604;&#1582;&#1591;&#1608;&#1575;&#1578; &#1575;&#1604;&#1605;&#1591;&#1604;&#1608;&#1576;&#1577;:' '' '' $false
Add-EmailBlock 'tap' 'steps' 'Steps (one per line)' 'list' ((@('Go to {tap_link}','Sign in with your university account <b>{upn}</b>. When you are asked for a password or a Temporary Access Pass, enter the pass above.','<b>Change your password</b> there (and set up Microsoft Authenticator if you are asked to).','From then on, sign in with your new password.') -join "`n")) ((@('&#1575;&#1601;&#1578;&#1581; &#1575;&#1604;&#1585;&#1575;&#1576;&#1591; {tap_link}','&#1587;&#1580;&#1617;&#1604; &#1575;&#1604;&#1583;&#1582;&#1608;&#1604; &#1576;&#1581;&#1587;&#1575;&#1576;&#1603; &#1575;&#1604;&#1580;&#1575;&#1605;&#1593;&#1610; <b><bdi>{upn}</bdi></b>. &#1593;&#1606;&#1583;&#1605;&#1575; &#1610;&#1615;&#1591;&#1604;&#1576; &#1605;&#1606;&#1603; &#1603;&#1604;&#1605;&#1577; &#1575;&#1604;&#1605;&#1585;&#1608;&#1585; &#1571;&#1608; &#1585;&#1605;&#1586; &#1575;&#1604;&#1608;&#1589;&#1608;&#1604; &#1575;&#1604;&#1605;&#1572;&#1602;&#1578;&#1548; &#1571;&#1583;&#1582;&#1604; &#1575;&#1604;&#1585;&#1605;&#1586; &#1571;&#1593;&#1604;&#1575;&#1607;.','<b>&#1594;&#1610;&#1617;&#1585; &#1603;&#1604;&#1605;&#1577; &#1575;&#1604;&#1605;&#1585;&#1608;&#1585;</b> &#1605;&#1606; &#1607;&#1606;&#1575;&#1603; (&#1608;&#1602;&#1605; &#1576;&#1573;&#1593;&#1583;&#1575;&#1583; &#1578;&#1591;&#1576;&#1610;&#1602; Microsoft Authenticator &#1573;&#1584;&#1575; &#1591;&#1615;&#1604;&#1576; &#1605;&#1606;&#1603; &#1584;&#1604;&#1603;).','&#1576;&#1593;&#1583; &#1584;&#1604;&#1603;&#1548; &#1587;&#1580;&#1617;&#1604; &#1575;&#1604;&#1583;&#1582;&#1608;&#1604; &#1576;&#1575;&#1587;&#1578;&#1582;&#1583;&#1575;&#1605; &#1603;&#1604;&#1605;&#1577; &#1575;&#1604;&#1605;&#1585;&#1608;&#1585; &#1575;&#1604;&#1580;&#1583;&#1610;&#1583;&#1577;.') -join "`n")) '' '' $false
Add-EmailBlock 'tap' 'closing' 'Last line' 'html' 'If the time has passed or the pass does not work, contact IT support for a new one.' '&#1573;&#1584;&#1575; &#1575;&#1606;&#1578;&#1607;&#1609; &#1575;&#1604;&#1608;&#1602;&#1578; &#1571;&#1608; &#1604;&#1605; &#1610;&#1593;&#1605;&#1604; &#1575;&#1604;&#1585;&#1605;&#1586;&#1548; &#1610;&#1615;&#1585;&#1580;&#1609; &#1575;&#1604;&#1578;&#1608;&#1575;&#1589;&#1604; &#1605;&#1593; &#1575;&#1604;&#1583;&#1593;&#1605; &#1575;&#1604;&#1601;&#1606;&#1610; &#1604;&#1604;&#1581;&#1589;&#1608;&#1604; &#1593;&#1604;&#1609; &#1585;&#1605;&#1586; &#1580;&#1583;&#1610;&#1583;.' '' '' $false
Add-EmailBlock 'tap' 'footer' 'Security notice at the bottom' 'html' 'If you did not ask for this, contact IT support straight away. IT will never ask you to reply with your password.' '&#1573;&#1584;&#1575; &#1604;&#1605; &#1578;&#1591;&#1604;&#1576; &#1584;&#1604;&#1603;&#1548; &#1578;&#1608;&#1575;&#1589;&#1604; &#1605;&#1593; &#1575;&#1604;&#1583;&#1593;&#1605; &#1575;&#1604;&#1601;&#1606;&#1610; &#1601;&#1608;&#1585;&#1611;&#1575;. &#1604;&#1606; &#1610;&#1591;&#1604;&#1576; &#1605;&#1606;&#1603; &#1575;&#1604;&#1583;&#1593;&#1605; &#1575;&#1604;&#1601;&#1606;&#1610; &#1571;&#1576;&#1583;&#1611;&#1575; &#1575;&#1604;&#1585;&#1583; &#1576;&#1603;&#1604;&#1605;&#1577; &#1575;&#1604;&#1605;&#1585;&#1608;&#1585; &#1575;&#1604;&#1582;&#1575;&#1589;&#1577; &#1576;&#1603;.' 'pw.footer' 'Shared with the other password e-mails.' $false
New-EmailDef 'temp' 'Temporary password (cloud)' 'Sent with a temporary password for a cloud (Microsoft Entra) account. The password is always shown in a box.' 'Your new password' @('first|First name (taken from the person''s account in your tenant)','last|Last name (same place)','full|First and last name together','greet|The name chosen in Name in the greeting (default: first name)','name|Full name of the person','upn|Account name (sign-in name)','signature|Your signature (set in Email settings)') @('pwOnce|Must change at first sign-in') 'Subject is the same one as in Email settings.'
Add-EmailBlock 'temp' 'hello' 'Greeting' 'html' 'Hello {greet},' '&#1605;&#1585;&#1581;&#1576;&#1611;&#1575; {greet}&#1548;' '' '' $false
Add-EmailBlock 'temp' 'intro' 'What happened' 'html' 'Your temporary password for <b>{upn}</b> has been reset by {signature}.' '&#1578;&#1605;&#1578; &#1573;&#1593;&#1575;&#1583;&#1577; &#1578;&#1593;&#1610;&#1610;&#1606; &#1603;&#1604;&#1605;&#1577; &#1575;&#1604;&#1605;&#1585;&#1608;&#1585; &#1575;&#1604;&#1605;&#1572;&#1602;&#1578;&#1577; &#1604;&#1581;&#1587;&#1575;&#1576;&#1603; <b><bdi>{upn}</bdi></b> &#1605;&#1606; &#1602;&#1616;&#1576;&#1604; {signature}.' '' '' $false
Add-EmailBlock 'temp' 'ruleOnce' 'Rule - must change at first sign-in' 'html' 'You will be asked to choose a new password the first time you sign in.' '&#1587;&#1610;&#1615;&#1591;&#1604;&#1576; &#1605;&#1606;&#1603; &#1575;&#1582;&#1578;&#1610;&#1575;&#1585; &#1603;&#1604;&#1605;&#1577; &#1605;&#1585;&#1608;&#1585; &#1580;&#1583;&#1610;&#1583;&#1577; &#1593;&#1606;&#1583; &#1578;&#1587;&#1580;&#1610;&#1604; &#1575;&#1604;&#1583;&#1582;&#1608;&#1604; &#1604;&#1571;&#1608;&#1604; &#1605;&#1585;&#1577;.' '' '' $false
Add-EmailBlock 'temp' 'ruleKeep' 'Rule - keep it safe' 'html' 'Please keep it safe and do not share it with anyone.' '&#1610;&#1615;&#1585;&#1580;&#1609; &#1575;&#1604;&#1575;&#1581;&#1578;&#1601;&#1575;&#1592; &#1576;&#1607;&#1575; &#1601;&#1610; &#1605;&#1603;&#1575;&#1606; &#1570;&#1605;&#1606; &#1608;&#1593;&#1583;&#1605; &#1605;&#1588;&#1575;&#1585;&#1603;&#1578;&#1607;&#1575; &#1605;&#1593; &#1571;&#1610; &#1588;&#1582;&#1589;.' '' '' $false
Add-EmailBlock 'temp' 'footer' 'Security notice at the bottom' 'html' 'If you did not ask for this, contact IT support straight away. IT will never ask you to reply with your password.' '&#1573;&#1584;&#1575; &#1604;&#1605; &#1578;&#1591;&#1604;&#1576; &#1584;&#1604;&#1603;&#1548; &#1578;&#1608;&#1575;&#1589;&#1604; &#1605;&#1593; &#1575;&#1604;&#1583;&#1593;&#1605; &#1575;&#1604;&#1601;&#1606;&#1610; &#1601;&#1608;&#1585;&#1611;&#1575;. &#1604;&#1606; &#1610;&#1591;&#1604;&#1576; &#1605;&#1606;&#1603; &#1575;&#1604;&#1583;&#1593;&#1605; &#1575;&#1604;&#1601;&#1606;&#1610; &#1571;&#1576;&#1583;&#1611;&#1575; &#1575;&#1604;&#1585;&#1583; &#1576;&#1603;&#1604;&#1605;&#1577; &#1575;&#1604;&#1605;&#1585;&#1608;&#1585; &#1575;&#1604;&#1582;&#1575;&#1589;&#1577; &#1576;&#1603;.' 'pw.footer' 'Shared with the other password e-mails.' $false
New-EmailDef 'mfa' 'Set up Microsoft Authenticator again' 'Sent from the Revoke MFA screen after the sign-in methods were removed: how to set up Microsoft Authenticator again. English and Arabic (empty the Arabic boxes to send English only).' 'Set up Microsoft Authenticator again' @('first|First name (from the account in your tenant)','last|Last name (same place)','full|First and last name together','greet|The name chosen in Name in the greeting (default: first name)','name|Full name of the person','upn|Account name (sign-in name)','signature|Your signature (set in Email settings)','mfa_link|Link to the security info page (Email settings)','note|Your own note typed on the Revoke MFA screen (empty when none)') @() 'Sent from the Revoke MFA screen. The subject can be changed here.'
Add-EmailBlock 'mfa' 'hello' 'Greeting' 'html' 'Hello {greet},' '&#1605;&#1585;&#1581;&#1576;&#1575;&#1611; {greet}&#1548;' '' '' $false
Add-EmailBlock 'mfa' 'intro' 'What happened' 'html' 'The sign-in verification (MFA) of your university account <b>{upn}</b> has been reset by {signature}. Your old Microsoft Authenticator / phone method no longer works - please set it up again.' '&#1578;&#1605;&#1578; &#1573;&#1593;&#1575;&#1583;&#1577; &#1578;&#1593;&#1610;&#1610;&#1606; &#1575;&#1604;&#1578;&#1581;&#1602;&#1602; &#1605;&#1606; &#1578;&#1587;&#1580;&#1610;&#1604; &#1575;&#1604;&#1583;&#1582;&#1608;&#1604; (MFA) &#1604;&#1581;&#1587;&#1575;&#1576;&#1603; &#1575;&#1604;&#1580;&#1575;&#1605;&#1593;&#1610; <b><bdi>{upn}</bdi></b> &#1576;&#1608;&#1575;&#1587;&#1591;&#1577; {signature}. &#1604;&#1605; &#1578;&#1593;&#1583; &#1591;&#1585;&#1610;&#1602;&#1577; Microsoft Authenticator &#1571;&#1608; &#1575;&#1604;&#1607;&#1575;&#1578;&#1601; &#1575;&#1604;&#1602;&#1583;&#1610;&#1605;&#1577; &#1578;&#1593;&#1605;&#1604; - &#1610;&#1585;&#1580;&#1609; &#1573;&#1593;&#1583;&#1575;&#1583;&#1607;&#1575; &#1605;&#1585;&#1577; &#1571;&#1582;&#1585;&#1609;.' '' '' $false
Add-EmailBlock 'mfa' 'stepsTitle' 'Title of the steps' 'html' 'How to set up Microsoft Authenticator (about 5 minutes):' '&#1603;&#1610;&#1601;&#1610;&#1577; &#1573;&#1593;&#1583;&#1575;&#1583; Microsoft Authenticator (&#1581;&#1608;&#1575;&#1604;&#1610; 5 &#1583;&#1602;&#1575;&#1574;&#1602;):' '' '' $false
Add-EmailBlock 'mfa' 'steps' 'Steps (one per line)' 'list' ((@('Install <b>Microsoft Authenticator</b> on your phone from the App Store (iPhone) or Google Play (Android).','On a computer, open {mfa_link} and sign in with <b>{upn}</b>.','Click <b>+ Add sign-in method</b>, choose <b>Microsoft Authenticator</b> and click <b>Next</b>.','In the app on your phone tap <b>+</b> &gt; <b>Work or school account</b> &gt; <b>Scan a QR code</b>, and scan the code shown on the computer.','Approve the test notification on your phone. Done - from now on you approve sign-ins with the app.')) -join "`n") ((@('&#1579;&#1576;&#1617;&#1578; &#1578;&#1591;&#1576;&#1610;&#1602; <b>Microsoft Authenticator</b> &#1593;&#1604;&#1609; &#1607;&#1575;&#1578;&#1601;&#1603; &#1605;&#1606; App Store (&#1570;&#1610;&#1601;&#1608;&#1606;) &#1571;&#1608; Google Play (&#1571;&#1606;&#1583;&#1585;&#1608;&#1610;&#1583;).','&#1593;&#1604;&#1609; &#1580;&#1607;&#1575;&#1586; &#1575;&#1604;&#1603;&#1605;&#1576;&#1610;&#1608;&#1578;&#1585;&#1548; &#1575;&#1601;&#1578;&#1581; {mfa_link} &#1608;&#1587;&#1580;&#1617;&#1604; &#1575;&#1604;&#1583;&#1582;&#1608;&#1604; &#1576;&#1575;&#1587;&#1578;&#1582;&#1583;&#1575;&#1605; <b><bdi>{upn}</bdi></b>.','&#1575;&#1590;&#1594;&#1591; &#1593;&#1604;&#1609; <b>+ &#1573;&#1590;&#1575;&#1601;&#1577; &#1591;&#1585;&#1610;&#1602;&#1577; &#1578;&#1587;&#1580;&#1610;&#1604; &#1583;&#1582;&#1608;&#1604;</b>&#1548; &#1608;&#1575;&#1582;&#1578;&#1585; <b>Microsoft Authenticator</b> &#1579;&#1605; <b>&#1575;&#1604;&#1578;&#1575;&#1604;&#1610;</b>.','&#1601;&#1610; &#1575;&#1604;&#1578;&#1591;&#1576;&#1610;&#1602; &#1593;&#1604;&#1609; &#1607;&#1575;&#1578;&#1601;&#1603; &#1575;&#1590;&#1594;&#1591; <b>+</b> &gt; <b>&#1581;&#1587;&#1575;&#1576; &#1575;&#1604;&#1593;&#1605;&#1604; &#1571;&#1608; &#1575;&#1604;&#1605;&#1572;&#1587;&#1587;&#1577; &#1575;&#1604;&#1578;&#1593;&#1604;&#1610;&#1605;&#1610;&#1577;</b> &gt; <b>&#1605;&#1587;&#1581; &#1585;&#1605;&#1586; QR</b>&#1548; &#1608;&#1575;&#1605;&#1587;&#1581; &#1575;&#1604;&#1585;&#1605;&#1586; &#1575;&#1604;&#1592;&#1575;&#1607;&#1585; &#1593;&#1604;&#1609; &#1575;&#1604;&#1603;&#1605;&#1576;&#1610;&#1608;&#1578;&#1585;.','&#1608;&#1575;&#1601;&#1602; &#1593;&#1604;&#1609; &#1575;&#1604;&#1573;&#1588;&#1593;&#1575;&#1585; &#1575;&#1604;&#1578;&#1580;&#1585;&#1610;&#1576;&#1610; &#1593;&#1604;&#1609; &#1607;&#1575;&#1578;&#1601;&#1603;. &#1575;&#1606;&#1578;&#1607;&#1609; - &#1605;&#1606; &#1575;&#1604;&#1570;&#1606; &#1601;&#1589;&#1575;&#1593;&#1583;&#1575;&#1611; &#1578;&#1608;&#1575;&#1601;&#1602; &#1593;&#1604;&#1609; &#1578;&#1587;&#1580;&#1610;&#1604;&#1575;&#1578; &#1575;&#1604;&#1583;&#1582;&#1608;&#1604; &#1605;&#1606; &#1575;&#1604;&#1578;&#1591;&#1576;&#1610;&#1602;.')) -join "`n") '' '' $false
Add-EmailBlock 'mfa' 'closing' 'Last line' 'html' 'If you are asked to set it up when you sign in, just follow the same steps on the screen. If something does not work, contact IT support.' '&#1573;&#1584;&#1575; &#1591;&#1615;&#1604;&#1576; &#1605;&#1606;&#1603; &#1575;&#1604;&#1573;&#1593;&#1583;&#1575;&#1583; &#1593;&#1606;&#1583; &#1578;&#1587;&#1580;&#1610;&#1604; &#1575;&#1604;&#1583;&#1582;&#1608;&#1604;&#1548; &#1601;&#1575;&#1578;&#1576;&#1593; &#1606;&#1601;&#1587; &#1575;&#1604;&#1582;&#1591;&#1608;&#1575;&#1578; &#1593;&#1604;&#1609; &#1575;&#1604;&#1588;&#1575;&#1588;&#1577;. &#1573;&#1584;&#1575; &#1604;&#1605; &#1610;&#1606;&#1580;&#1581; &#1571;&#1610; &#1588;&#1610;&#1569;&#1548; &#1578;&#1608;&#1575;&#1589;&#1604; &#1605;&#1593; &#1575;&#1604;&#1583;&#1593;&#1605; &#1575;&#1604;&#1601;&#1606;&#1610;.' '' '' $false
Add-EmailBlock 'mfa' 'footer' 'Security notice at the bottom' 'html' 'If you did not ask for this, contact IT support straight away. IT will never ask you for your password or a code.' '&#1573;&#1584;&#1575; &#1604;&#1605; &#1578;&#1591;&#1604;&#1576; &#1584;&#1604;&#1603;&#1548; &#1578;&#1608;&#1575;&#1589;&#1604; &#1605;&#1593; &#1575;&#1604;&#1583;&#1593;&#1605; &#1575;&#1604;&#1601;&#1606;&#1610; &#1601;&#1608;&#1585;&#1575;&#1611;. &#1604;&#1606; &#1610;&#1591;&#1604;&#1576; &#1605;&#1606;&#1603; &#1602;&#1587;&#1605; &#1578;&#1602;&#1606;&#1610;&#1577; &#1575;&#1604;&#1605;&#1593;&#1604;&#1608;&#1605;&#1575;&#1578; &#1571;&#1576;&#1583;&#1575;&#1611; &#1603;&#1604;&#1605;&#1577; &#1575;&#1604;&#1605;&#1585;&#1608;&#1585; &#1571;&#1608; &#1571;&#1610; &#1585;&#1605;&#1586;.' '' '' $false
# v2.9.0: e-mail sent to a NEW user (Create AD users) with the username and the password. The e-mail itself is built by New-NewUserMailHtml (Screen-AdCreate.ps1).
New-EmailDef 'newuser' 'New user account - username and password' 'Sent from the Create AD users screen (tick "E-mail the username and password") to the new person. The username and the password are shown in boxes. English and Arabic (empty the Arabic boxes to send English only).' 'Your new account' @('first|First name','last|Last name','full|First and last name together','greet|The name chosen in Name in the greeting (default: first name)','name|Full name of the person','username|The username (sAMAccountName)','upn|Sign-in name (UPN)','signature|Your signature (set in Email settings)','change_link|Link to change the password','mfa_link|Link to set up Microsoft Authenticator') @('pwOnce|One-time password (must change at first sign-in)') 'Sent from the Create AD users screen. The password is always in the e-mail. Own HTML must contain {password}; {username} is optional.'
Add-EmailBlock 'newuser' 'hello' 'Greeting' 'html' 'Hello {greet},' '&#1605;&#1585;&#1581;&#1576;&#1575;&#1611; {greet}&#1548;' '' '' $false
Add-EmailBlock 'newuser' 'intro' 'What happened' 'html' 'Your account <b>{upn}</b> has been created by {signature}. Here are your sign-in details.' '&#1578;&#1605; &#1573;&#1606;&#1588;&#1575;&#1569; &#1581;&#1587;&#1575;&#1576;&#1603; <b>{upn}</b> &#1576;&#1608;&#1575;&#1587;&#1591;&#1577; {signature}.' '' '' $false
Add-EmailBlock 'newuser' 'userLabel' 'Label for the username' 'html' 'Username:' '&#1575;&#1587;&#1605; &#1575;&#1604;&#1605;&#1587;&#1578;&#1582;&#1583;&#1605;:' '' '' $false
Add-EmailBlock 'newuser' 'pwLabel' 'Label for the password' 'html' 'Password:' '&#1603;&#1604;&#1605;&#1577; &#1575;&#1604;&#1605;&#1585;&#1608;&#1585;:' '' '' $false
Add-EmailBlock 'newuser' 'once' 'Note - one-time password' 'html' '<b>This is a one-time password.</b> You must change it the first time you sign in - you will be asked to choose a new password.' '<b>&#1607;&#1584;&#1607; &#1603;&#1604;&#1605;&#1577; &#1605;&#1585;&#1608;&#1585; &#1604;&#1605;&#1585;&#1577; &#1608;&#1575;&#1581;&#1583;&#1577;.</b> &#1587;&#1610;&#1615;&#1591;&#1604;&#1576; &#1605;&#1606;&#1603; &#1575;&#1582;&#1578;&#1610;&#1575;&#1585; &#1603;&#1604;&#1605;&#1577; &#1605;&#1585;&#1608;&#1585; &#1580;&#1583;&#1610;&#1583;&#1577; &#1593;&#1606;&#1583; &#1571;&#1608;&#1604; &#1578;&#1587;&#1580;&#1610;&#1604; &#1583;&#1582;&#1608;&#1604;.' '' '' $false
Add-EmailBlock 'newuser' 'normal' 'Note - normal password' 'html' '<b>This is your password.</b> Please keep it safe and do not share it with anyone.' '<b>&#1607;&#1584;&#1607; &#1603;&#1604;&#1605;&#1577; &#1575;&#1604;&#1605;&#1585;&#1608;&#1585; &#1575;&#1604;&#1582;&#1575;&#1589;&#1577; &#1576;&#1603;.</b> &#1610;&#1585;&#1580;&#1609; &#1575;&#1604;&#1575;&#1581;&#1578;&#1601;&#1575;&#1592; &#1576;&#1607;&#1575; &#1601;&#1610; &#1605;&#1603;&#1575;&#1606; &#1570;&#1605;&#1606; &#1608;&#1593;&#1583;&#1605; &#1605;&#1588;&#1575;&#1585;&#1603;&#1578;&#1607;&#1575; &#1605;&#1593; &#1571;&#1581;&#1583;.' '' '' $false
Add-EmailBlock 'newuser' 'closing' 'Last line' 'html' 'If the sign-in details do not work, contact IT support.' '&#1573;&#1584;&#1575; &#1604;&#1605; &#1578;&#1593;&#1605;&#1604; &#1576;&#1610;&#1575;&#1606;&#1575;&#1578; &#1575;&#1604;&#1583;&#1582;&#1608;&#1604;&#1548; &#1610;&#1585;&#1580;&#1609; &#1575;&#1604;&#1578;&#1608;&#1575;&#1589;&#1604; &#1605;&#1593; &#1575;&#1604;&#1583;&#1593;&#1605; &#1575;&#1604;&#1601;&#1606;&#1610;.' '' '' $false
Add-EmailBlock 'newuser' 'footer' 'Security notice at the bottom' 'html' ($script:EmailDefs['ad'].blocks['footer'].en) ($script:EmailDefs['ad'].blocks['footer'].ar) 'ad.footer' '' $false
New-EmailDef 'guest' 'Guest invitation' 'Sent to an outside person you invite as a guest (only when you choose to send it from a sender mailbox). Your own message and the button are added automatically. English and Arabic (empty the Arabic boxes to send English only).' 'You have been invited' @('name|Name of the guest as you typed it','first|First word of the guest name','last|The rest of the guest name','full|The whole guest name','greet|The name chosen in Name in the greeting (default: the whole name)','org|Your organization name (only when known)','url|The invitation link (the button and the fallback link)') @('org|Organization name is known','msg|Has your own message') 'Subject can be changed on the Guest users screen each time.'
Add-EmailBlock 'guest' 'helloNamed' 'Greeting (name known)' 'html' 'Hello {greet},' '&#1605;&#1585;&#1581;&#1576;&#1575;&#1611; {greet}&#1548;' '' '' $false
Add-EmailBlock 'guest' 'helloPlain' 'Greeting (no name)' 'html' 'Hello,' '&#1605;&#1585;&#1581;&#1576;&#1575;&#1611;&#1548;' '' '' $false
Add-EmailBlock 'guest' 'intro' 'Invitation line (organization known)' 'html' 'You have been invited to join <b>{org}</b> as a guest.' '&#1578;&#1605;&#1578; &#1583;&#1593;&#1608;&#1578;&#1603; &#1604;&#1604;&#1575;&#1606;&#1590;&#1605;&#1575;&#1605; &#1573;&#1604;&#1609; <b><bdi>{org}</bdi></b> &#1603;&#1590;&#1610;&#1601;.' '' '' $false
Add-EmailBlock 'guest' 'introPlain' 'Invitation line (organization not known)' 'html' 'You have been invited as a guest.' '&#1578;&#1605;&#1578; &#1583;&#1593;&#1608;&#1578;&#1603; &#1603;&#1590;&#1610;&#1601;.' '' '' $false
Add-EmailBlock 'guest' 'instruction' 'Instruction above the button' 'html' 'Press the button, sign in with this email address and accept the invitation:' '&#1575;&#1590;&#1594;&#1591; &#1593;&#1604;&#1609; &#1575;&#1604;&#1586;&#1585;&#1548; &#1608;&#1587;&#1580;&#1617;&#1604; &#1575;&#1604;&#1583;&#1582;&#1608;&#1604; &#1576;&#1575;&#1587;&#1578;&#1582;&#1583;&#1575;&#1605; &#1593;&#1606;&#1608;&#1575;&#1606; &#1575;&#1604;&#1576;&#1585;&#1610;&#1583; &#1575;&#1604;&#1573;&#1604;&#1603;&#1578;&#1585;&#1608;&#1606;&#1610; &#1607;&#1584;&#1575;&#1548; &#1579;&#1605; &#1575;&#1602;&#1576;&#1604; &#1575;&#1604;&#1583;&#1593;&#1608;&#1577;:' '' '' $false
Add-EmailBlock 'guest' 'button' 'Button text' 'html' 'Accept invitation' '&#1602;&#1576;&#1608;&#1604; &#1575;&#1604;&#1583;&#1593;&#1608;&#1577;' '' '' $false
Add-EmailBlock 'guest' 'fallback' 'Text above the fallback link' 'html' 'If the button does not work, copy this link into your browser:' '&#1573;&#1584;&#1575; &#1604;&#1605; &#1610;&#1593;&#1605;&#1604; &#1575;&#1604;&#1586;&#1585;&#1548; &#1575;&#1606;&#1587;&#1582; &#1607;&#1584;&#1575; &#1575;&#1604;&#1585;&#1575;&#1576;&#1591; &#1608;&#1575;&#1604;&#1589;&#1602;&#1607; &#1601;&#1610; &#1575;&#1604;&#1605;&#1578;&#1589;&#1601;&#1581;:' '' '' $false
New-EmailDef 'mbxShared' 'Shared mailbox - how to open it' 'Sent to each person who gets access to a shared mailbox. Their access (Full Access, Send As, Send on behalf) is listed automatically.' 'Shared mailbox {mailbox}: how to open it' @('first|First name (taken from the person''s account in your tenant)','last|Last name (same place)','full|First and last name together','greet|The name chosen in Name in the greeting (default: first name)','name|Name of the mailbox','addr|Address of the mailbox','auto|The auto-open sentence (chosen by the access)') @('fullAccess|Full Access','autoMap|Opens by itself (automapping)','sendAs|Send As','sendOnBehalf|Send on behalf') 'Subject placeholder: {mailbox}. You can still change the subject on the Shared mailbox screen each time.'
Add-EmailBlock 'mbxShared' 'hello' 'Greeting' 'html' 'Hello {greet},' '&#1605;&#1585;&#1581;&#1576;&#1611;&#1575; {greet}&#1548;' '' '' $false
Add-EmailBlock 'mbxShared' 'intro' 'What happened' 'html' 'The mailbox <b>{name}</b> ({addr}) is now a <b>shared mailbox</b> and you have access to it.' '&#1571;&#1589;&#1576;&#1581; &#1589;&#1606;&#1583;&#1608;&#1602; &#1575;&#1604;&#1576;&#1585;&#1610;&#1583; <b><bdi>{name}</bdi></b> (<bdi>{addr}</bdi>) &#1589;&#1606;&#1583;&#1608;&#1602; &#1576;&#1585;&#1610;&#1583; &#1605;&#1588;&#1578;&#1585;&#1603;&#1611;&#1575;&#1548; &#1608;&#1604;&#1583;&#1610;&#1603; &#1589;&#1604;&#1575;&#1581;&#1610;&#1577; &#1575;&#1604;&#1608;&#1589;&#1608;&#1604; &#1573;&#1604;&#1610;&#1607;.' '' '' $false
Add-EmailBlock 'mbxShared' 'rightsTitle' 'Title of the access list' 'html' 'Your access' '&#1589;&#1604;&#1575;&#1581;&#1610;&#1575;&#1578;&#1603;:' '' '' $false
Add-EmailBlock 'mbxShared' 'rFull' 'Access - Full Access' 'html' '<b>Full Access</b> - read and manage the mail (delete, organise, drafts).' '&#1608;&#1589;&#1608;&#1604; &#1603;&#1575;&#1605;&#1604;: &#1575;&#1602;&#1585;&#1571; &#1575;&#1604;&#1576;&#1585;&#1610;&#1583; &#1608;&#1571;&#1583;&#1585;&#1607; (&#1581;&#1584;&#1601;&#1548; &#1578;&#1606;&#1592;&#1610;&#1605;&#1548; &#1605;&#1587;&#1608;&#1583;&#1575;&#1578;).' '' '' $false
Add-EmailBlock 'mbxShared' 'rSendAs' 'Access - Send As' 'html' '<b>Send As</b> - what you send looks as if the mailbox sent it (people see only the shared address).' '&#1575;&#1604;&#1573;&#1585;&#1587;&#1575;&#1604; &#1576;&#1575;&#1587;&#1605; &#1589;&#1606;&#1583;&#1608;&#1602; &#1575;&#1604;&#1576;&#1585;&#1610;&#1583;: &#1610;&#1585;&#1609; &#1575;&#1604;&#1605;&#1587;&#1578;&#1604;&#1605; &#1593;&#1606;&#1608;&#1575;&#1606; &#1589;&#1606;&#1583;&#1608;&#1602; &#1575;&#1604;&#1576;&#1585;&#1610;&#1583; &#1575;&#1604;&#1605;&#1588;&#1578;&#1585;&#1603; &#1601;&#1602;&#1591;.' '' '' $false
Add-EmailBlock 'mbxShared' 'rBehalf' 'Access - Send on behalf' 'html' '<b>Send on behalf</b> - people see "your name on behalf of the mailbox".' '&#1575;&#1604;&#1573;&#1585;&#1587;&#1575;&#1604; &#1606;&#1610;&#1575;&#1576;&#1577;&#1611; &#1593;&#1606;: &#1610;&#1585;&#1609; &#1575;&#1604;&#1605;&#1587;&#1578;&#1604;&#1605; "&#1575;&#1587;&#1605;&#1603; &#1606;&#1610;&#1575;&#1576;&#1577;&#1611; &#1593;&#1606; &#1589;&#1606;&#1583;&#1608;&#1602; &#1575;&#1604;&#1576;&#1585;&#1610;&#1583;".' '' '' $false
Add-EmailBlock 'mbxShared' 'openTitle' 'Title of how to open' 'html' 'How to open it' '&#1603;&#1610;&#1601;&#1610;&#1577; &#1601;&#1578;&#1581;&#1607;' '' '' $false
Add-EmailBlock 'mbxShared' 'open' 'How to open (one per line)' 'list' ((@('<b>Outlook on your computer (Windows or Mac):</b> {auto} Close and open Outlook again if you do not see it.','<b>Outlook on the web:</b> go to <b>outlook.office.com</b>, click your picture (top right), choose <b>Open another mailbox</b>, type <b>{addr}</b> and press Open. It opens in a new window.','<b>Phone:</b> open Outlook on the web in your phone''s browser, or use the Outlook app if the mailbox is listed there.') -join "`n")) ((@('<b>Outlook &#1593;&#1604;&#1609; &#1575;&#1604;&#1581;&#1575;&#1587;&#1608;&#1576; (Windows &#1571;&#1608; Mac):</b> &#1610;&#1592;&#1607;&#1585; &#1589;&#1606;&#1583;&#1608;&#1602; &#1575;&#1604;&#1576;&#1585;&#1610;&#1583; &#1578;&#1604;&#1602;&#1575;&#1574;&#1610;&#1611;&#1575; &#1578;&#1581;&#1578; &#1589;&#1606;&#1583;&#1608;&#1602; &#1576;&#1585;&#1610;&#1583;&#1603; &#1601;&#1610; &#1602;&#1575;&#1574;&#1605;&#1577; &#1575;&#1604;&#1605;&#1580;&#1604;&#1583;&#1575;&#1578; &#1582;&#1604;&#1575;&#1604; &#1587;&#1575;&#1593;&#1577; &#1578;&#1602;&#1585;&#1610;&#1576;&#1611;&#1575;. &#1573;&#1584;&#1575; &#1604;&#1605; &#1610;&#1592;&#1607;&#1585;&#1548; &#1571;&#1594;&#1604;&#1602; Outlook &#1608;&#1575;&#1601;&#1578;&#1581;&#1607; &#1605;&#1606; &#1580;&#1583;&#1610;&#1583;.','<b>Outlook &#1593;&#1604;&#1609; &#1575;&#1604;&#1608;&#1610;&#1576;:</b> &#1575;&#1601;&#1578;&#1581; <bdi>outlook.office.com</bdi> &#1608;&#1575;&#1590;&#1594;&#1591; &#1593;&#1604;&#1609; &#1589;&#1608;&#1585;&#1578;&#1603; (&#1571;&#1593;&#1604;&#1609; &#1575;&#1604;&#1589;&#1601;&#1581;&#1577;) &#1579;&#1605; &#1575;&#1582;&#1578;&#1585; "&#1601;&#1578;&#1581; &#1589;&#1606;&#1583;&#1608;&#1602; &#1576;&#1585;&#1610;&#1583; &#1570;&#1582;&#1585;" &#1608;&#1575;&#1603;&#1578;&#1576; <bdi>{addr}</bdi> &#1579;&#1605; &#1575;&#1590;&#1594;&#1591; "&#1601;&#1578;&#1581;". &#1610;&#1615;&#1601;&#1578;&#1581; &#1601;&#1610; &#1606;&#1575;&#1601;&#1584;&#1577; &#1580;&#1583;&#1610;&#1583;&#1577;.','<b>&#1575;&#1604;&#1607;&#1575;&#1578;&#1601;:</b> &#1575;&#1601;&#1578;&#1581; Outlook &#1593;&#1604;&#1609; &#1575;&#1604;&#1608;&#1610;&#1576; &#1605;&#1606; &#1605;&#1578;&#1589;&#1601;&#1581; &#1575;&#1604;&#1607;&#1575;&#1578;&#1601;&#1548; &#1571;&#1608; &#1575;&#1587;&#1578;&#1582;&#1583;&#1605; &#1578;&#1591;&#1576;&#1610;&#1602; Outlook &#1573;&#1584;&#1575; &#1603;&#1575;&#1606; &#1589;&#1606;&#1583;&#1608;&#1602; &#1575;&#1604;&#1576;&#1585;&#1610;&#1583; &#1592;&#1575;&#1607;&#1585;&#1611;&#1575; &#1601;&#1610;&#1607;.') -join "`n")) '' '' $false
Add-EmailBlock 'mbxShared' 'autoYes' 'Sentence {auto} when it opens by itself' 'html' 'It appears by itself under your own mailbox in the folder list within about an hour.' '' '' '' $true
Add-EmailBlock 'mbxShared' 'autoNo' 'Sentence {auto} when it does not' 'html' 'Add it from the folder list (right-click your mailbox name &gt; Add shared folder) or use Outlook on the web.' '' '' '' $true
Add-EmailBlock 'mbxShared' 'howTitle' 'Title of how it works' 'html' 'How it works' '&#1603;&#1610;&#1601; &#1610;&#1593;&#1605;&#1604;' '' '' $false
Add-EmailBlock 'mbxShared' 'how' 'How it works (one per line)' 'list' ((@('You do not sign in to the shared mailbox itself and it has no password of its own - you always use your own account.','Everyone with access sees the same mail. When someone reads or moves a message, the others see it too.','To send from the shared mailbox: start a new message, click <b>From</b> and choose <b>{addr}</b> (or <b>Other email address</b> and type it).','If you do not see the mailbox after one hour, contact IT Support.') -join "`n")) ((@('&#1604;&#1575; &#1578;&#1587;&#1580;&#1617;&#1604; &#1575;&#1604;&#1583;&#1582;&#1608;&#1604; &#1573;&#1604;&#1609; &#1589;&#1606;&#1583;&#1608;&#1602; &#1575;&#1604;&#1576;&#1585;&#1610;&#1583; &#1575;&#1604;&#1605;&#1588;&#1578;&#1585;&#1603; &#1606;&#1601;&#1587;&#1607; &#1608;&#1604;&#1610;&#1587; &#1604;&#1607; &#1603;&#1604;&#1605;&#1577; &#1605;&#1585;&#1608;&#1585;&#1563; &#1578;&#1587;&#1578;&#1582;&#1583;&#1605; &#1581;&#1587;&#1575;&#1576;&#1603; &#1575;&#1604;&#1588;&#1582;&#1589;&#1610; &#1583;&#1575;&#1574;&#1605;&#1611;&#1575;.','&#1580;&#1605;&#1610;&#1593; &#1605;&#1606; &#1604;&#1583;&#1610;&#1607;&#1605; &#1589;&#1604;&#1575;&#1581;&#1610;&#1577; &#1610;&#1585;&#1608;&#1606; &#1575;&#1604;&#1576;&#1585;&#1610;&#1583; &#1606;&#1601;&#1587;&#1607;&#1548; &#1608;&#1593;&#1606;&#1583;&#1605;&#1575; &#1610;&#1602;&#1585;&#1571; &#1571;&#1581;&#1583;&#1607;&#1605; &#1585;&#1587;&#1575;&#1604;&#1577; &#1571;&#1608; &#1610;&#1606;&#1602;&#1604;&#1607;&#1575; &#1610;&#1585;&#1575;&#1607;&#1575; &#1575;&#1604;&#1570;&#1582;&#1585;&#1608;&#1606; &#1603;&#1584;&#1604;&#1603;.','&#1604;&#1604;&#1573;&#1585;&#1587;&#1575;&#1604; &#1605;&#1606; &#1589;&#1606;&#1583;&#1608;&#1602; &#1575;&#1604;&#1576;&#1585;&#1610;&#1583; &#1575;&#1604;&#1605;&#1588;&#1578;&#1585;&#1603;: &#1571;&#1606;&#1588;&#1574; &#1585;&#1587;&#1575;&#1604;&#1577; &#1580;&#1583;&#1610;&#1583;&#1577;&#1548; &#1575;&#1590;&#1594;&#1591; "&#1605;&#1606;" &#1608;&#1575;&#1582;&#1578;&#1585; <bdi>{addr}</bdi> (&#1571;&#1608; "&#1593;&#1606;&#1608;&#1575;&#1606; &#1576;&#1585;&#1610;&#1583; &#1570;&#1582;&#1585;" &#1608;&#1575;&#1603;&#1578;&#1576;&#1607;).','&#1573;&#1584;&#1575; &#1604;&#1605; &#1610;&#1592;&#1607;&#1585; &#1589;&#1606;&#1583;&#1608;&#1602; &#1575;&#1604;&#1576;&#1585;&#1610;&#1583; &#1576;&#1593;&#1583; &#1587;&#1575;&#1593;&#1577;&#1548; &#1578;&#1608;&#1575;&#1589;&#1604; &#1605;&#1593; &#1575;&#1604;&#1583;&#1593;&#1605; &#1575;&#1604;&#1601;&#1606;&#1610;.') -join "`n")) '' '' $false
New-EmailDef 'mbxRegular' 'Mailbox is a normal mailbox again' 'Sent to the people when a shared mailbox is converted back to a normal mailbox.' 'Your mailbox {mailbox} is a normal mailbox again' @('first|First name (taken from the person''s account in your tenant)','last|Last name (same place)','full|First and last name together','greet|The name chosen in Name in the greeting (default: first name)','name|Name of the mailbox','addr|Address of the mailbox','sspr|Link to reset the password','mfa|Link to set up the second sign-in step') @() 'Subject placeholder: {mailbox}.'
Add-EmailBlock 'mbxRegular' 'hello' 'Greeting' 'html' 'Hello {greet},' '&#1605;&#1585;&#1581;&#1576;&#1611;&#1575; {greet}&#1548;' '' '' $false
Add-EmailBlock 'mbxRegular' 'intro' 'What happened' 'html' 'The mailbox <b>{name}</b> ({addr}) is no longer a shared mailbox. It is now a normal mailbox with its own sign-in.' '&#1604;&#1605; &#1610;&#1593;&#1583; &#1589;&#1606;&#1583;&#1608;&#1602; &#1575;&#1604;&#1576;&#1585;&#1610;&#1583; <b><bdi>{name}</bdi></b> (<bdi>{addr}</bdi>) &#1589;&#1606;&#1583;&#1608;&#1602; &#1576;&#1585;&#1610;&#1583; &#1605;&#1588;&#1578;&#1585;&#1603;&#1611;&#1575;. &#1571;&#1589;&#1576;&#1581; &#1589;&#1606;&#1583;&#1608;&#1602; &#1576;&#1585;&#1610;&#1583; &#1593;&#1575;&#1583;&#1610;&#1611;&#1575; &#1604;&#1607; &#1578;&#1587;&#1580;&#1610;&#1604; &#1583;&#1582;&#1608;&#1604; &#1582;&#1575;&#1589; &#1576;&#1607;.' '' '' $false
Add-EmailBlock 'mbxRegular' 'signTitle' 'Title of the sign-in steps' 'html' 'Signing in' '&#1578;&#1587;&#1580;&#1610;&#1604; &#1575;&#1604;&#1583;&#1582;&#1608;&#1604;' '' '' $false
Add-EmailBlock 'mbxRegular' 'signList' 'Sign-in steps (one per line)' 'list' ((@('Go to <b>outlook.office.com</b> and sign in with <b>{addr}</b> and the password of the account.','If you do not know the password, you can reset it yourself here: <a href="{sspr}">{sspr}</a>','You may be asked to register a second sign-in step (MFA): <a href="{mfa}">{mfa}</a>','If the mailbox still shows in your Outlook as a shared mailbox, close Outlook and open it again. If it does not work, contact IT Support.') -join "`n")) ((@('&#1575;&#1601;&#1578;&#1581; <bdi>outlook.office.com</bdi> &#1608;&#1587;&#1580;&#1617;&#1604; &#1575;&#1604;&#1583;&#1582;&#1608;&#1604; &#1576;&#1575;&#1604;&#1593;&#1606;&#1608;&#1575;&#1606; <bdi>{addr}</bdi> &#1608;&#1603;&#1604;&#1605;&#1577; &#1605;&#1585;&#1608;&#1585; &#1575;&#1604;&#1581;&#1587;&#1575;&#1576;.','&#1573;&#1584;&#1575; &#1603;&#1606;&#1578; &#1604;&#1575; &#1578;&#1593;&#1585;&#1601; &#1603;&#1604;&#1605;&#1577; &#1575;&#1604;&#1605;&#1585;&#1608;&#1585;&#1548; &#1610;&#1605;&#1603;&#1606;&#1603; &#1573;&#1593;&#1575;&#1583;&#1577; &#1578;&#1593;&#1610;&#1610;&#1606;&#1607;&#1575; &#1576;&#1606;&#1601;&#1587;&#1603; &#1605;&#1606; &#1607;&#1606;&#1575;: <a href="{sspr}"><bdi>{sspr}</bdi></a>','&#1602;&#1583; &#1578;&#1615;&#1591;&#1604;&#1576; &#1605;&#1606;&#1603; &#1578;&#1587;&#1580;&#1610;&#1604; &#1591;&#1585;&#1610;&#1602;&#1577; &#1575;&#1604;&#1578;&#1581;&#1602;&#1602; &#1576;&#1582;&#1591;&#1608;&#1578;&#1610;&#1606;: <a href="{mfa}"><bdi>{mfa}</bdi></a>','&#1573;&#1584;&#1575; &#1603;&#1575;&#1606; &#1589;&#1606;&#1583;&#1608;&#1602; &#1575;&#1604;&#1576;&#1585;&#1610;&#1583; &#1605;&#1575; &#1586;&#1575;&#1604; &#1610;&#1592;&#1607;&#1585; &#1601;&#1610; Outlook &#1603;&#1589;&#1606;&#1583;&#1608;&#1602; &#1605;&#1588;&#1578;&#1585;&#1603;&#1548; &#1571;&#1594;&#1604;&#1602; Outlook &#1608;&#1575;&#1601;&#1578;&#1581;&#1607; &#1605;&#1606; &#1580;&#1583;&#1610;&#1583;. &#1608;&#1573;&#1606; &#1575;&#1587;&#1578;&#1605;&#1585;&#1578; &#1575;&#1604;&#1605;&#1588;&#1603;&#1604;&#1577; &#1578;&#1608;&#1575;&#1589;&#1604; &#1605;&#1593; &#1575;&#1604;&#1583;&#1593;&#1605; &#1575;&#1604;&#1601;&#1606;&#1610;.') -join "`n")) '' '' $false

# ---- saved changes ----
# Returns the saved changes as a hashtable of hashtables (store name -> { en, ar }). Empty when nothing is saved or the file is damaged.
# Cached by file time: if the file did not change since the last read, the cached copy is returned.
function Get-EmailStore {
    $f = $script:EmailTplFile
    if (-not (Test-Path $f)) { $script:EmailStoreCache = $null; return @{} }
    $t = (Get-Item $f).LastWriteTimeUtc.Ticks
    if ($script:EmailStoreCache -and $script:EmailStoreStamp -eq $t) { return $script:EmailStoreCache }
    $h = @{}
    try {
        $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $e = @{}; foreach ($q in $p.Value.PSObject.Properties) { $e[$q.Name] = "$($q.Value)" }; $h[$p.Name] = $e }
    } catch {}
    $script:EmailStoreCache = $h; $script:EmailStoreStamp = $t
    $h
}
# Saves the changes table. An empty table deletes the file (everything is default again). Written to a .tmp file first and then moved,
# so a crash during the write cannot leave a half-written file.
function Save-EmailStore($h) {
    if (-not $h.Count) { if (Test-Path $script:EmailTplFile) { Remove-Item $script:EmailTplFile -Force }; $script:EmailStoreCache = $null; return }
    $o = [ordered]@{}; foreach ($k in ($h.Keys | Sort-Object)) { $o[$k] = $h[$k] }
    $json = $o | ConvertTo-Json -Depth 4
    # ConvertTo-Json writes < > & ' as \u codes; turn them back into the real characters so the file is easy to read in a text editor.
    $json = [regex]::Replace($json, '\\u(003c|003e|0026|0027)', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })   # readable in a text editor
    $tmp = "$($script:EmailTplFile).tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item $tmp $script:EmailTplFile -Force
    $script:EmailStoreCache = $null
}
# Returns the text of one block: $id = e-mail, $k = block key, $lang = 'en' or 'ar'. Order of priority: unsaved text being previewed,
# then the saved text, then the built-in default.
function Get-EmailText($id, $k, $lang) {
    $b = $script:EmailDefs[$id].blocks[$k]
    if (-not $b) { return '' }
    $sk = $b.store
    if ($script:EmailPreview -and $script:EmailPreview.ContainsKey($sk) -and $script:EmailPreview[$sk].ContainsKey($lang)) { return "$($script:EmailPreview[$sk][$lang])" }
    $st = Get-EmailStore
    if ($st.ContainsKey($sk) -and $st[$sk].ContainsKey($lang)) { return "$($st[$sk][$lang])" }
    "$($b[$lang])"
}
# Fills in the {placeholders} of a text. $v = plain values (HTML-encoded here so they are safe), $raw = ready-made HTML (links, password box, logo).
# Unknown {words} are left as they are.
function Expand-EmailText([string]$t, [hashtable]$v, [hashtable]$raw) {
    # {name} -> the value (HTML-safe), or the ready-made HTML for the link / sentence placeholders; an unknown {word} is left as it is
    if (-not $t) { return '' }
    $sb = New-Object Text.StringBuilder; $pos = 0
    foreach ($m in [regex]::Matches($t, '\{(\w+)\}')) {
        [void]$sb.Append($t.Substring($pos, $m.Index - $pos)); $n = $m.Groups[1].Value
        if ($raw -and $raw.ContainsKey($n)) { [void]$sb.Append([string]$raw[$n]) }
        elseif ($v -and $v.ContainsKey($n)) { [void]$sb.Append([Net.WebUtility]::HtmlEncode([string]$v[$n])) }
        else { [void]$sb.Append($m.Value) }
        $pos = $m.Index + $m.Length
    }
    [void]$sb.Append($t.Substring($pos)); $sb.ToString()
}
# v2.5.7: remember every placeholder value used while an e-mail is built, so "your own HTML" can use the same values
# Placeholder values remembered while an e-mail is built, so a custom HTML can use the same values (see Format-EmailLayout).
$script:EmailVarsSeen = @{}; $script:EmailExtraVars = $null; $script:EmailPreviewCustom = $null
# Remembers the placeholder values of the current e-mail. The English pass wins; Arabic only adds names not seen yet.
function Add-EmailVarsSeen($id, $lang, $v, $raw) {
    if (-not $script:EmailVarsSeen.ContainsKey($id)) { $script:EmailVarsSeen[$id] = @{} }
    $m = $script:EmailVarsSeen[$id]
    if ($v) { foreach ($x in @($v.Keys)) { if ($lang -eq 'en' -or -not $m.ContainsKey($x)) { $m[$x] = [Net.WebUtility]::HtmlEncode([string]$v[$x]) } } }
    if ($raw) { foreach ($x in @($raw.Keys)) { if ($lang -eq 'en' -or -not $m.ContainsKey($x)) { $m[$x] = [string]$raw[$x] } } }
}
# Returns one finished text block (placeholders filled in) and records the values used.
function Get-EmailPart($id, $k, $lang, $v, $raw) { Add-EmailVarsSeen $id $lang $v $raw; Expand-EmailText (Get-EmailText $id $k $lang) $v $raw }
# Returns a 'list' block as HTML <li> items (one per non-empty line). $liStyle is an optional inline style for each <li>.
function Get-EmailItems($id, $k, $lang, $v, $raw, $liStyle) {
    Add-EmailVarsSeen $id $lang $v $raw
    # a list text: one line = one bullet
    $o = if ($liStyle) { "<li style=""$liStyle"">" } else { '<li>' }
    (@((Get-EmailText $id $k $lang) -split '\r?\n' | Where-Object { "$_".Trim() } | ForEach-Object { $o + (Expand-EmailText $_ $v $raw) + '</li>' }) -join '')
}
# Returns the subject of an e-mail: the password e-mails use the subjects in the mail settings; the others use the saved subject or the default.
function Get-EmailSubject($id) {
    if ($id -in 'ad', 'temp') { return "$((Get-MailCfg).subject)" }
    if ($id -eq 'tap') { return "$((Get-MailCfg).subjectTap)" }
    $st = Get-EmailStore
    if ($st.ContainsKey("subject.$id") -and "$($st["subject.$id"].en)".Trim()) { return "$($st["subject.$id"].en)".Trim() }
    $script:EmailDefs[$id].subject
}

# ---- Arabic letters <-> HTML character codes ----
# Turns every non-ASCII character (for example Arabic) into an HTML code like &#1605; . Characters above 65535 (surrogate pairs) become one code.
function ConvertTo-EmailCodes([string]$s) {
    $sb = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $s.Length; $i++) {
        $c = [int]$s[$i]
        if ($c -lt 128) { [void]$sb.Append($s[$i]) }
        elseif ([char]::IsHighSurrogate($s[$i]) -and $i + 1 -lt $s.Length) { [void]$sb.Append('&#' + [char]::ConvertToUtf32($s[$i], $s[$i + 1]) + ';'); $i++ }
        else { [void]$sb.Append('&#' + $c + ';') }
    }
    $sb.ToString()
}
# The opposite: turns &#NNNN; codes back into real characters for the screen. Surrogate halves (55296-57343) and values over 1114111 are not valid and stay unchanged.
function ConvertFrom-EmailCodes([string]$s) {
    [regex]::Replace($s, '&#(\d{3,7});', { param($m) $n = [int]$m.Groups[1].Value; if ($n -ge 128 -and $n -le 1114111 -and -not ($n -ge 55296 -and $n -le 57343)) { [char]::ConvertFromUtf32($n) } else { $m.Value } })
}
# Safety check for a typed text: max 4000 characters and nothing that can run code in an e-mail (script, form, frame, style, on...= events, javascript:, data:text/html). Throws if bad.
function Test-EmailHtml([string]$s, [string]$what) {
    if ($s.Length -gt 4000) { throw "$what is too long (up to 4000 characters)." }
    if ($s -match '(?i)<\s*/?\s*(script|iframe|object|embed|form|style|link|meta|base|input|button|textarea|svg)\b' -or $s -match '(?i)\son[a-z]+\s*=' -or $s -match '(?i)javascript\s*:' -or $s -match '(?i)data\s*:\s*text/html') {
        throw "$what has something an e-mail text may not contain (script, form, frame, style, or an on...= event). Use only simple tags like <b>, <i>, <a href=""https://..."">, <br>."
    }
}

# ---- layout: which language is on top, and one picture ----
# Saved as "layout.<id>" in email-templates.json: order (en-ar | ar-en | en | ar), imgPos (top | bottom), imgW (width in pixels), img (file name in the email-images folder).
# Layout typed on the screen but not saved yet (used only while the preview is built).
$script:EmailPreviewLayout = $null
# Folder with the pictures (logos) used in e-mails.
$script:EmailImgDir = Join-Path $Root 'email-images'
# Returns the layout of an e-mail: language order, picture position/alignment/width/file and the greeting style. Saved values are checked and wrong
# ones fall back to the default; the width is limited to 40-600 pixels. The guest e-mail greets with the full name, the others with the first name.
function Get-EmailLayout($id) {
    $o = @{ order = 'en-ar'; imgPos = 'top'; imgAlign = 'left'; imgW = '220'; img = ''; greet = $(if ($id -eq 'guest') { 'full' } else { 'first' }) }
    $st = Get-EmailStore
    foreach ($src in @($(if ($st.ContainsKey("layout.$id")) { $st["layout.$id"] }), $script:EmailPreviewLayout)) {
        if (-not $src) { continue }
        foreach ($k in @('order', 'imgPos', 'imgAlign', 'imgW', 'greet')) { if ($src.ContainsKey($k) -and "$($src[$k])") { $o[$k] = "$($src[$k])" } }
        if ($src.ContainsKey('img')) { $o.img = "$($src.img)" }
    }
    if ($o.order -notin 'en-ar', 'ar-en', 'en', 'ar') { $o.order = 'en-ar' }
    if ($o.imgPos -notin 'top', 'afterHello', 'beforeSig', 'bottom') { $o.imgPos = 'top' }
    if ($o.imgAlign -notin 'left', 'center', 'right') { $o.imgAlign = 'left' }
    if ($o.greet -notin 'first', 'last', 'full') { $o.greet = $(if ($id -eq 'guest') { 'full' } else { 'first' }) }
    $w = 220; if (-not [int]::TryParse($o.imgW, [ref]$w)) { $w = 220 }; $o.imgW = [string][Math]::Min(600, [Math]::Max(40, $w))
    $o
}
# Returns the saved picture of an e-mail { name, type, bytes }, or $null when there is none or the file is missing. The name is cut to a plain file name (no folders).
function Get-EmailImage($id) {
    $st = Get-EmailStore
    if (-not $st.ContainsKey("layout.$id")) { return $null }
    $fn = [IO.Path]::GetFileName("$($st["layout.$id"].img)"); if (-not $fn) { return $null }
    $f = Join-Path $script:EmailImgDir $fn; if (-not (Test-Path $f)) { return $null }
    $ext = [IO.Path]::GetExtension($fn).ToLower()
    $type = switch ($ext) { '.png' { 'image/png' } '.gif' { 'image/gif' } default { 'image/jpeg' } }
    @{ name = $fn; type = $type; bytes = [IO.File]::ReadAllBytes($f) }
}
# Returns the Microsoft Graph 'fileAttachment' list that attaches the picture inline (contentId emailimg, used in the HTML as cid:emailimg).
function Get-EmailAttach($id) {
    $i = Get-EmailImage $id; if (-not $i) { return @() }
    @(@{ '@odata.type' = '#microsoft.graph.fileAttachment'; name = $i.name; contentType = $i.type; contentBytes = [Convert]::ToBase64String($i.bytes); isInline = $true; contentId = 'emailimg' })
}

# ---- v1.98.2: signature block and light/dark e-mails ----
# First non-empty line of a signature (who signs).
function Get-EmailSigFirst($sig) { ("$sig" -split "\r?\n" | Where-Object { "$_".Trim() } | Select-Object -First 1) }
# v1.98.8: custom signature - HTML made by the designer in Settings > Email sender (anything that could run code is removed)
# Cleans a custom signature written as HTML: max 20000 characters; removes script/style/frame/form... blocks, their loose tags, on...= attributes
# and javascript:/vbscript:/data: links (replaced by '#').
function Get-SafeSigHtml([string]$h) {
    $h = "$h"; if ($h.Length -gt 20000) { throw 'The custom signature is too long (more than 20000 characters).' }
    $h = [regex]::Replace($h, '(?is)<(script|style|iframe|object|embed|form|svg|math)\b.*?</\1\s*>', '')
    $h = [regex]::Replace($h, '(?is)<(script|style|iframe|object|embed|form|input|button|meta|link|base|svg|math)\b[^>]*>', '')
    $h = [regex]::Replace($h, '(?is)\son[a-z]+\s*=\s*("[^"]*"|''[^'']*''|[^\s>]+)', '')
    $h = [regex]::Replace($h, '(?is)(href|src)\s*=\s*(["''])\s*(javascript|vbscript|data):[^"'']*\2', '$1="#"')
    $h.Trim()
}
# Wraps custom signature HTML in a div (right aligned for Arabic). Returns '' when there is no signature.
function Get-CustomSigBlock([string]$h, [switch]$Rtl) { if (-not $h) { return '' }; '<div style="margin:22px 0 4px;text-align:' + $(if ($Rtl) { 'right' } else { 'left' }) + '">' + $h + '</div>' }
# Builds the signature HTML. With a custom signature (mail settings sigMode = custom) that is used, unless -Standard is given.
# -Rtl = right-to-left (Arabic). Otherwise: a short blue bar, the first line in bold and the other lines small and grey.
function Get-EmailSigHtml($sig, [switch]$Rtl, [switch]$Standard) {
    if (-not $Standard) { $mc = $null; try { $mc = Get-MailCfg } catch {}; if ($mc -and "$($mc.sigMode)" -eq 'custom' -and "$($mc.sigHtml)".Trim()) { return (Get-CustomSigBlock (Get-SafeSigHtml "$($mc.sigHtml)") -Rtl:$Rtl) } }
    # line 1 = who signs (bold), the other lines (department, phone, address ...) smaller and grey, above them a short blue line
    $l = @("$sig" -split "\r?\n" | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if (-not $l.Count) { return '' }
    $e = { param($t) [Net.WebUtility]::HtmlEncode("$t") }
    $rest = if ($l.Count -gt 1) { '<br><span class="st-mute" style="color:#64748b;font-size:12.5px;line-height:1.6">' + (($l | Select-Object -Skip 1 | ForEach-Object { & $e $_ }) -join '<br>') + '</span>' } else { '' }
    $al = if ($Rtl) { 'right' } else { 'left' }
    '<div style="margin:22px 0 4px;text-align:' + $al + '"><div class="st-sigbar" style="display:inline-block;width:44px;height:3px;background:#2563eb;font-size:0;line-height:0">&nbsp;</div>' +
    '<div class="st-text" style="padding-top:8px;font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#1f2937"><b>' + (& $e $l[0]) + '</b>' + $rest + '</div></div>'
}
# Adds dark-mode support to finished e-mail HTML: coloured styles get CSS classes, and a <style> block recolours them when the reader uses dark mode.
# Returns the HTML wrapped in a div. The map below links an inline colour to its class.
function Add-EmailTheme([string]$html) {
    # Marks the coloured parts with classes, so a phone or PC in dark mode shows dark colours (Apple Mail, Outlook for Mac / iOS / Android,
    # Outlook on the web); in light mode nothing changes. Outlook for Windows darkens e-mails by itself.
    $map = [ordered]@{ 'background:#2563eb' = 'st-btn'; 'background:#fef3c7' = 'st-code'; 'background:#f1f5f9' = 'st-soft'; 'background:#eff6ff' = 'st-soft'; 'color:#64748b' = 'st-mute'; 'color:#1f2937' = 'st-text'; 'color:#0f172a' = 'st-text' }
    # For each tag with a style attribute: add classes for the colours found in it (skip tags that already have a class).
    $html = [regex]::Replace($html, '<(\w+)([^<>]*?)\sstyle="([^"]*)"', {
        param($m)
        if ($m.Groups[2].Value -match '\bclass=') { return $m.Value }
        $cl = @(); foreach ($k in $map.Keys) { if ($m.Groups[3].Value -like "*$k*") { $cl += $map[$k] } }
        if ($m.Groups[3].Value -match 'border[^;]*#(e5e7eb|cbd5e1|bfdbfe)') { $cl += 'st-line' }
        if (-not $cl.Count) { return $m.Value }
        '<' + $m.Groups[1].Value + $m.Groups[2].Value + ' class="' + (($cl | Select-Object -Unique) -join ' ') + '" style="' + $m.Groups[3].Value + '"'
    })
    $css = '<meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark"><style>:root{color-scheme:light dark;supported-color-schemes:light dark}' +
        '@media (prefers-color-scheme:dark){.st-wrap{background:#0f172a!important}.st-text{color:#e5e7eb!important}.st-mute{color:#9ca3af!important}.st-soft{background:#1e293b!important;color:#e5e7eb!important}' +
        '.st-code{background:#422006!important;color:#fde68a!important;border-color:#a16207!important}.st-btn{background:#3b82f6!important;color:#ffffff!important}.st-line{border-color:#334155!important}.st-sigbar{background:#60a5fa!important}a{color:#93c5fd}}' +
        '[data-ogsc] .st-text{color:#e5e7eb!important}[data-ogsc] .st-mute{color:#9ca3af!important}[data-ogsb] .st-soft{background:#1e293b!important}[data-ogsb] .st-code{background:#422006!important}[data-ogsc] .st-code{color:#fde68a!important}</style>'
    $css + '<div class="st-wrap st-text" style="color:#1f2937">' + $html + '</div>'
}
# v2.5.7: "your own HTML" for an e-mail - pasted on the Email messages screen; {placeholders} are filled in when it is sent
# Returns the custom HTML for an e-mail { on, html } if it is switched on and not empty, otherwise $null. While previewing, the unsaved version is used.
function Get-EmailCustom($id) {
    if ($null -ne $script:EmailPreviewCustom) { if ($script:EmailPreviewCustom.on -and "$($script:EmailPreviewCustom.html)".Trim()) { return $script:EmailPreviewCustom }; return $null }
    $st = Get-EmailStore; $c = $st["custom.$id"]
    if ($c -and "$($c.on)" -eq 'True' -and "$($c.html)".Trim()) { return @{ on = $true; html = "$($c.html)" } }
    $null
}
# Safety check for pasted custom HTML (max 300 KB, nothing that can run code). The password e-mails must contain {password}, otherwise the person would not get it.
function Test-EmailCustomHtml([string]$h, $id) {
    if ($h.Length -gt 300KB) { throw 'The HTML is too long (up to 300 KB).' }
    if ($h -match '(?i)<\s*/?\s*(script|iframe|object|embed|form|input|button|textarea|base|meta\s+http-equiv)\b' -or $h -match '(?i)\son[a-z]+\s*=' -or $h -match '(?i)javascript\s*:' -or $h -match '(?i)data\s*:\s*text/html') {
        throw 'The HTML has something an e-mail may not contain (script, frame, form, button, an on...= event or javascript:). E-mail programs block these anyway - remove them.'
    }
    if ($id -in 'ad', 'temp', 'tap', 'newuser' -and $h -notmatch '\{password\}') { throw 'Put {password} where the new password (or pass) should appear - otherwise the person never gets it.' }
}
# Final step for every e-mail. With custom HTML: fill its {placeholders} with the values seen while building the built-in e-mail (plus the logo).
# Without: apply the layout (Format-EmailLayoutRaw) and the dark-mode theme.
function Format-EmailLayout($id, [string]$html) {
    $c = Get-EmailCustom $id
    $seen = $script:EmailVarsSeen[$id]; $script:EmailVarsSeen.Remove($id)
    if ($c) {
        $vars = @{}; if ($seen) { foreach ($k in $seen.Keys) { $vars[$k] = $seen[$k] } }
        if ($script:EmailExtraVars) { foreach ($k in $script:EmailExtraVars.Keys) { $vars[$k] = $script:EmailExtraVars[$k] } }
        $L = Get-EmailLayout $id; $vars['logo'] = $(if (Get-EmailImage $id) { '<img src="cid:emailimg" alt="" width="' + $L.imgW + '" style="width:' + $L.imgW + 'px;max-width:100%;height:auto;border:0">' } else { '' })
        return (Expand-EmailText $c.html @{} $vars)
    }
    Add-EmailTheme (Format-EmailLayoutRaw $id $html)
}
# Applies the layout to the built-in e-mail HTML: puts the chosen language first (or only one language) and inserts the logo picture
# at {logo} or at the chosen position (top / after the greeting / before the signature / bottom). Arabic part starts at <div dir="rtl" lang="ar".
function Format-EmailLayoutRaw($id, [string]$html) {
    # puts the language you chose on top and adds the picture (sent as an inline attachment, shown with cid:emailimg)
    $L = Get-EmailLayout $id; $img = Get-EmailImage $id
    if (-not $img) { $html = $html.Replace('{logo}', '') }
    if ($L.order -eq 'en-ar' -and -not $img) { return $html }
    $open = $html.Substring(0, $html.IndexOf('>') + 1)
    # $open is the first tag (the wrapper div); the body is everything inside it.
    $body = $html.Substring($open.Length, $html.Length - $open.Length - 6)   # without the last </div>
    $m = $body.IndexOf('<div dir="rtl" lang="ar"')
    if ($m -ge 0 -and $L.order -ne 'en-ar') {
        $en = $body.Substring(0, $m); $ar = $body.Substring($m)
        switch ($L.order) {
            'ar-en' { $ar = [regex]::Replace($ar, 'border-top:2px solid #e5e7eb;margin-top:\d+px;padding-top:14px', 'border-bottom:2px solid #e5e7eb;margin-bottom:22px;padding-bottom:14px', 'None'); $body = $ar + $en }
            'en'    { $body = $en }
            'ar'    { $body = [regex]::Replace($ar, 'border-top:2px solid #e5e7eb;margin-top:\d+px;padding-top:14px', '', 'None') }
        }
    }
    if ($img) {
        $tag = '<p style="margin:0 0 16px"><img src="cid:emailimg" alt="" width="' + $L.imgW + '" style="width:' + $L.imgW + 'px;max-width:100%;height:auto;display:block;border:0"></p>'
        # v2.5.8: the logo can go anywhere - {logo} typed in any text puts it exactly there; otherwise the chosen place and alignment
        $al = $L.imgAlign; $mg = $(if ($al -eq 'center') { 'margin-left:auto;margin-right:auto;' } elseif ($al -eq 'right') { 'margin-left:auto;' } else { '' })
        $tag = '<p style="margin:0 0 16px;text-align:' + $al + '"><img src="cid:emailimg" alt="" width="' + $L.imgW + '" style="width:' + $L.imgW + 'px;max-width:100%;height:auto;display:block;border:0;' + $mg + '"></p>'
        if ($body -match '\{logo\}') { $body = $body.Replace('{logo}', $tag.Replace('margin:0 0 16px', 'margin:8px 0')) }
        else { switch ($L.imgPos) {
            'bottom' { $body = $body + $tag.Replace('margin:0 0 16px', 'margin:16px 0 0') }
            'afterHello' { $i = $body.IndexOf('</p>'); if ($i -ge 0) { $body = $body.Substring(0, $i + 4) + $tag.Replace('margin:0 0 16px', 'margin:12px 0') + $body.Substring($i + 4) } else { $body = $tag + $body } }
            'beforeSig' { $i = $body.LastIndexOf('<div style="margin:22px 0 4px'); if ($i -lt 0) { $i = $body.LastIndexOf('<p style="color:#64748b;font-size:12px') }; if ($i -ge 0) { $body = $body.Substring(0, $i) + $tag.Replace('margin:0 0 16px', 'margin:16px 0') + $body.Substring($i) } else { $body = $body + $tag } }
            default { $body = $tag + $body }
        } }
    }
    $open + $body + '</div>'
}
# Builds the password / Temporary Access Pass e-mail. $s = what to send (secret, ad/tap flags, name...), $cfg = mail settings.
# The password is shown in a monospace box; the extra variable is cleared afterwards even if an error happens.
function New-PwMailHtml($s, $cfg) {
    $pw = [Net.WebUtility]::HtmlEncode("$($s.secret)")
    $script:EmailExtraVars = @{ password = '<span style="font-size:20px;font-family:Consolas,monospace;background:#f1f5f9;border:1px solid #cbd5e1;border-radius:8px;padding:10px 14px;display:inline-block;letter-spacing:1px;color:#0f172a">' + $pw + '</span>'; password_text = $pw }
    try { Format-EmailLayout $(if ($s.ad) { 'ad' } elseif ($s.tap) { 'tap' } else { 'temp' }) (New-PwMailHtmlRaw $s $cfg) } finally { $script:EmailExtraVars = $null }
}
# Builds the guest invitation e-mail (the raw design lives in another file) and applies the layout.
function New-GuestMailHtml($name, $url, $msg, $org, $sig) { Format-EmailLayout 'guest' (New-GuestMailHtmlRaw $name $url $msg $org $sig) }
# Builds the shared / normal mailbox e-mail ($kind = 'regular' or 'shared') and applies the layout.
function New-MbxMailHtml($kind, $first, $name, $addr, $rights, $msg, $sig, $cfg, $names = $null) { Format-EmailLayout $(if ($kind -eq 'regular') { 'mbxRegular' } else { 'mbxShared' }) (New-MbxMailHtmlRaw $kind $first $name $addr $rights $msg $sig $cfg $names) }
# ---- the person's name: from the account in YOUR tenant ----
# Looks up the first/last/display name of the person in YOUR tenant (Microsoft Graph Get-MgUser, needs User.Read.All) by sign-in name, then by e-mail.
# Returns $null when not connected or not found - so a Gmail/Yahoo address never gives a wrong name.
function Get-EmailTenantName($addr) {
    # first / last name of the account owner, read from your tenant (Microsoft Entra) - not from the address the e-mail goes to (Gmail, Yahoo ...)
    $a = "$addr".Trim(); if (-not $a -or -not $script:Who) { return $null }
    try { $u = Get-MgUser -UserId $a -Property GivenName, Surname, DisplayName -ErrorAction Stop; if ($u) { return @{ given = "$($u.GivenName)"; sn = "$($u.Surname)"; disp = "$($u.DisplayName)" } } } catch {}
    if ($a -match '^[^@\s'']+@[^@\s'']+$') {
        try { $l = @(Get-MgUser -Filter "mail eq '$a'" -Property GivenName, Surname, DisplayName -Top 1 -ErrorAction Stop); if ($l.Count) { return @{ given = "$($l[0].GivenName)"; sn = "$($l[0].Surname)"; disp = "$($l[0].DisplayName)" } } } catch {}
    }
    $null
}
# Builds {first} {last} {full} {greet}. If only a display name exists it is split at the first space. {greet} follows the layout choice.
function Get-EmailNames($id, $given, $surname, $display) {
    # {first} {last} {full} and {greet} (the one you chose under "Name in the greeting")
    $g = "$given".Trim(); $s = "$surname".Trim(); $dn = "$display".Trim()
    if (-not $g -and -not $s -and $dn) { $p = $dn -split '\s+', 2; $g = $p[0]; if ($p.Count -gt 1) { $s = $p[1] } }
    $full = ("$g $s").Trim(); if (-not $full) { $full = $dn }
    $greet = switch ((Get-EmailLayout $id).greet) { 'last' { if ($s) { $s } else { $g } } 'full' { $full } default { $g } }
    if (-not $greet) { $greet = $full }
    @{ first = $g; last = $s; full = $full; greet = $greet }
}
# Checks an uploaded picture: max 500 KB and the first bytes must be a PNG (89 50 4E 47), JPG (FF D8 FF) or GIF (47 49 46 38). Returns the file ending.
function Test-EmailPicture([byte[]]$b) {
    if ($b.Length -gt 500KB) { throw 'The picture is too big (up to 500 KB). Make it smaller, for example 600 pixels wide.' }
    if ($b.Length -ge 8 -and $b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47) { return '.png' }
    if ($b.Length -ge 3 -and $b[0] -eq 0xFF -and $b[1] -eq 0xD8 -and $b[2] -eq 0xFF) { return '.jpg' }
    if ($b.Length -ge 4 -and $b[0] -eq 0x47 -and $b[1] -eq 0x49 -and $b[2] -eq 0x46 -and $b[3] -eq 0x38) { return '.gif' }
    throw 'Use a PNG, JPG or GIF picture.'
}

# ---- what the screen shows ----
# Builds everything the screen needs for one e-mail: texts (current and default, shown with real Arabic letters), subject, variants,
# layout and custom HTML. 'shared' marks blocks that are shared with another e-mail.
function Get-EmailView($id) {
    $def = $script:EmailDefs[$id]; $st = Get-EmailStore
    $blocks = @(foreach ($b in $def.blocks.Values) {
        $cur = @{ en = (Get-EmailText $id $b.k 'en'); ar = (Get-EmailText $id $b.k 'ar') }
        [ordered]@{ k = $b.k; label = $b.label; kind = $b.kind; note = $b.note; enOnly = $b.enOnly; shared = [bool]($b.store -notlike "$id.*")
            en = (ConvertFrom-EmailCodes $cur.en); ar = (ConvertFrom-EmailCodes $cur.ar); enDef = (ConvertFrom-EmailCodes $b.en); arDef = (ConvertFrom-EmailCodes $b.ar) }
    })
    $subj = Get-EmailSubject $id
    $subjEdited = $subj -ne $def.subject
    [ordered]@{ id = $id; title = $def.title; desc = $def.desc; note = $def.note
        vars = @($def.vars | ForEach-Object { $p = $_ -split '\|', 2; [ordered]@{ n = $p[0]; d = $p[1] } })
        variants = @($def.variants | ForEach-Object { $p = $_ -split '\|', 2; [ordered]@{ k = $p[0]; d = $p[1] } })
        subject = $subj; subjectDef = $def.subject; subjectEdited = $subjEdited; blocks = $blocks
        layout = (Get-EmailLayoutView $id)
        custom = $(if ($st["custom.$id"]) { @{ on = ("$($st["custom.$id"].on)" -eq 'True'); html = "$($st["custom.$id"].html)" } } else { @{ on = $false; html = '' } })
        customVars = @($(if ($id -in 'ad', 'temp', 'tap', 'newuser') { @{ n = 'password'; d = 'The new password (or pass) in a box' }; @{ n = 'password_text'; d = 'The password as plain text' } })) }
}
# Layout for the screen, taken from the SAVED values only (the preview layout is switched off for a moment), with the picture as a data: URL.
function Get-EmailLayoutView($id) {
    $saved = $script:EmailPreviewLayout; $script:EmailPreviewLayout = $null
    try { $L = Get-EmailLayout $id; $i = Get-EmailImage $id } finally { $script:EmailPreviewLayout = $saved }
    [ordered]@{ order = $L.order; greet = $L.greet; imgPos = $L.imgPos; imgAlign = $L.imgAlign; imgW = [int]$L.imgW; hasImg = [bool]$i; imgName = $(if ($i) { $i.name } else { '' }); imgData = $(if ($i) { 'data:' + $i.type + ';base64,' + [Convert]::ToBase64String($i.bytes) } else { '' }) }
}
# The views of all e-mails.
function Get-EmailAll { @($script:EmailDefs.Keys | ForEach-Object { Get-EmailView $_ }) }

# Input: the texts typed on the screen. Output: a table like the saved file, keeping only languages that differ from the default.
# Each text is checked (Test-EmailHtml); line breaks are joined for single-paragraph blocks and kept for lists.
function ConvertTo-EmailPosted($id, $posted) {
    # the texts typed on the screen -> a table keyed like the saved file; only the languages that differ from the default are kept
    $def = $script:EmailDefs[$id]; $o = @{}
    foreach ($b in $def.blocks.Values) {
        $p = $posted."$($b.k)"; if ($null -eq $p) { continue }
        $e = @{}
        foreach ($l in 'en', 'ar') {
            if ($l -eq 'ar' -and $b.enOnly) { continue }
            if ($null -eq $p.$l) { continue }
            $t = (("$($p.$l)" -replace '\r\n', "`n").Trim("`n", ' '))
            if ($b.kind -ne 'list') { $t = ($t -replace '\s*\n\s*', ' ').Trim() }
            Test-EmailHtml $t "'$($b.label)'"
            $code = ConvertTo-EmailCodes $t
            if ($code -ne "$($b[$l])") { $e[$l] = $code }
        }
        if (-not $o.ContainsKey($b.store)) { $o[$b.store] = @{} }
        foreach ($k in $e.Keys) { $o[$b.store][$k] = $e[$k] }
    }
    $o
}

# Endpoint: /api/email-tpl-list - no input. Sends all e-mails with their texts and the path of the saved file.
$ScreenHandlers['/api/email-tpl-list'] = {
    Send $ctx @{ ok = $true; emails = (Get-EmailAll); file = $script:EmailTplFile }
}

# Endpoint: /api/email-tpl-save - body { id, subject, blocks, layout }. Saves one e-mail. Only differences from the default are stored: a value equal to
# the default is removed. The password e-mails keep their subject in the mail settings file instead of email-templates.json.
$ScreenHandlers['/api/email-tpl-save'] = {
    $id = "$($d.id)"; if (-not $script:EmailDefs.Contains($id)) { throw 'Unknown e-mail.' }
    $def = $script:EmailDefs[$id]
    $new = ConvertTo-EmailPosted $id $d.blocks
    $subj = "$($d.subject)".Trim()
    if ($subj.Length -gt 250 -or $subj -match '[\r\n<>]') { throw 'The subject is too long or has characters it cannot have.' }
    if (-not $subj) { $subj = $def.subject }
    # Make an editable copy of the saved table (the cached one must not be changed directly).
    $st = @{}; $old = Get-EmailStore; foreach ($k in $old.Keys) { $st[$k] = @{} + $old[$k] }
    # shared blocks and these blocks: replace what this e-mail owns with what was posted
    foreach ($b in $def.blocks.Values) { if ($b.store -like "$id.*" -or $new.ContainsKey($b.store)) { $st.Remove($b.store) } }
    foreach ($sk in $new.Keys) { if ($new[$sk].Count) { $st[$sk] = $new[$sk] } }
    if ($id -in 'ad', 'temp', 'tap') {
        $c = Get-MailCfg; if ($id -eq 'tap') { $c.subjectTap = $subj } else { $c.subject = $subj }
        ($c | ConvertTo-Json) | Out-File $script:MailCfgFile -Encoding utf8
    } else {
        if ($subj -ne $def.subject) { $st["subject.$id"] = @{ en = $subj } } else { $st.Remove("subject.$id") }
    }
    # Layout values: each is validated and removed again when it equals the default; width is limited to 40-600 (default 220).
    $lay = @{}; if ($st.ContainsKey("layout.$id")) { $lay = @{} + $st["layout.$id"] }
    $lo = "$($d.layout.order)"; if ($lo -in 'en-ar', 'ar-en', 'en', 'ar') { if ($lo -eq 'en-ar') { $lay.Remove('order') } else { $lay.order = $lo } }
    $lg = "$($d.layout.greet)"; $dg = $(if ($id -eq 'guest') { 'full' } else { 'first' }); if ($lg -in 'first', 'last', 'full') { if ($lg -eq $dg) { $lay.Remove('greet') } else { $lay.greet = $lg } }
    $lp = "$($d.layout.imgPos)"; if ($lp -in 'top', 'afterHello', 'beforeSig', 'bottom') { if ($lp -eq 'top') { $lay.Remove('imgPos') } else { $lay.imgPos = $lp } }
    $la = "$($d.layout.imgAlign)"; if ($la -in 'left', 'center', 'right') { if ($la -eq 'left') { $lay.Remove('imgAlign') } else { $lay.imgAlign = $la } }
    $lw = 0; if ([int]::TryParse("$($d.layout.imgW)", [ref]$lw)) { $lw = [Math]::Min(600, [Math]::Max(40, $lw)); if ($lw -eq 220) { $lay.Remove('imgW') } else { $lay.imgW = "$lw" } }
    if ($lay.Count) { $st["layout.$id"] = $lay } else { $st.Remove("layout.$id") }
    Save-EmailStore $st
    Send $ctx @{ ok = $true; email = (Get-EmailView $id) }
}

# Endpoint: /api/email-tpl-reset - body { id }. Removes all saved changes of one e-mail (texts, subject, layout, picture file) and resets the
# subject in the mail settings for the password e-mails. Sends the e-mail again plus the full list (shared blocks may have changed).
$ScreenHandlers['/api/email-tpl-reset'] = {
    $id = "$($d.id)"; if (-not $script:EmailDefs.Contains($id)) { throw 'Unknown e-mail.' }
    $def = $script:EmailDefs[$id]
    $st = @{}; $old = Get-EmailStore; foreach ($k in $old.Keys) { $st[$k] = @{} + $old[$k] }
    foreach ($b in $def.blocks.Values) { $st.Remove($b.store) }
    $st.Remove("subject.$id")
    if ($st.ContainsKey("layout.$id")) { $fn = [IO.Path]::GetFileName("$($st["layout.$id"].img)"); if ($fn) { Remove-Item (Join-Path $script:EmailImgDir $fn) -Force -ErrorAction SilentlyContinue } }
    $st.Remove("layout.$id")
    if ($id -in 'ad', 'temp', 'tap') {
        $c = Get-MailCfg; $dc = [ordered]@{ subject = 'Your new password'; subjectTap = 'Your university account password' }
        if ($id -eq 'tap') { $c.subjectTap = $dc.subjectTap } else { $c.subject = $dc.subject }
        ($c | ConvertTo-Json) | Out-File $script:MailCfgFile -Encoding utf8
    }
    Save-EmailStore $st
    Send $ctx @{ ok = $true; email = (Get-EmailView $id); all = (Get-EmailAll) }
}

# Endpoint: /api/email-tpl-preview - body { id, variant, blocks, subject, layout, custom }. Nothing is saved. The typed values are placed in temporary
# variables, the real e-mail is built with made-up sample data, and the variables are always cleared again (finally). Sends { html, subject }.
$ScreenHandlers['/api/email-tpl-preview'] = {
    # builds the real e-mail with sample data, using the texts typed on the screen (not yet saved)
    $id = "$($d.id)"; if (-not $script:EmailDefs.Contains($id)) { throw 'Unknown e-mail.' }
    $vr = $d.variant
    # Helper: is the preview checkbox $k ticked?
    $on = { param($k) [bool]($vr -and $vr."$k") }
    $c = Get-MailCfg
    $script:EmailPreview = ConvertTo-EmailPosted $id $d.blocks
    if ($null -ne $d.custom) { $script:EmailPreviewCustom = @{ on = [bool]$d.custom.on; html = "$($d.custom.html)" }; if ($script:EmailPreviewCustom.on -and "$($d.custom.html)".Trim()) { Test-EmailCustomHtml "$($d.custom.html)" '' } }
    $script:EmailPreviewLayout = @{}; foreach ($k in 'order', 'imgPos', 'imgAlign', 'imgW', 'greet') { if ($d.layout -and "$($d.layout.$k)") { $script:EmailPreviewLayout[$k] = "$($d.layout.$k)" } }
    try {
        $sample = @{ name = 'Sara Ahmed'; upn = 'sara.ahmed@contoso.com'; given = 'Sara'; sn = 'Ahmed' }
        # One branch per e-mail type, each calling the same builder the real sending code uses.
        $html = switch ($id) {
            'ad'   { New-PwMailHtml @{ ad = $true; pwOnce = (& $on 'pwOnce'); name = $sample.name; given = $sample.given; sn = $sample.sn; upn = $sample.upn; secret = 'Tr#7mKp2vQ9x' } $c }
            'temp' { New-PwMailHtml @{ pwOnce = (& $on 'pwOnce'); name = $sample.name; given = $sample.given; sn = $sample.sn; upn = $sample.upn; secret = 'Tr#7mKp2vQ9x' } $c }
            'tap'  { New-PwMailHtml @{ tap = $true; at = (Get-Date); mins = 480; once = (& $on 'once'); name = $sample.name; given = $sample.given; sn = $sample.sn; upn = $sample.upn; secret = 'A7f2K9xQ4pLm' } $c }
            'guest' { New-GuestMailHtml $(if (& $on 'org') { 'Maria Lopez' } else { '' }) 'https://login.microsoftonline.com/redeem?rd=sample-invitation-link' $(if (& $on 'msg') { 'Welcome! You can now open our shared project site.' } else { '' }) $(if (& $on 'org') { 'Contoso University' } else { '' }) "$($c.signature)" }
            'mbxShared' { New-MbxMailHtml 'shared' 'Sara' 'Finance Team' 'finance@contoso.com' ([pscustomobject]@{ fullAccess = (& $on 'fullAccess'); autoMap = (& $on 'autoMap'); sendAs = (& $on 'sendAs'); sendOnBehalf = (& $on 'sendOnBehalf') }) '' "$($c.signature)" $c (Get-EmailNames 'mbxShared' 'Sara' 'Ahmed' 'Sara Ahmed') }
            'newuser' { New-NewUserMailHtml @{ name = $sample.name; given = $sample.given; sn = $sample.sn; upn = $sample.upn; sam = 'sara.ahmed'; secret = 'Tr#7mKp2vQ9x'; pwOnce = (& $on 'pwOnce') } $c }
            'mfa' { New-MfaMailHtml @{ name = $sample.name; given = $sample.given; sn = $sample.sn; upn = $sample.upn; note = '' } $c }
            'mbxRegular' { New-MbxMailHtml 'regular' 'Sara' 'Finance Team' 'finance@contoso.com' $null '' "$($c.signature)" $c (Get-EmailNames 'mbxRegular' 'Sara' 'Ahmed' 'Sara Ahmed') }
        }
    } finally { $script:EmailPreview = $null; $script:EmailPreviewLayout = $null; $script:EmailPreviewCustom = $null }
    $pi = Get-EmailImage $id
    # The browser cannot show an e-mail attachment (cid:), so the picture is embedded as a data: URL for the preview.
    if ($pi) { $html = "$html".Replace('cid:emailimg', 'data:' + $pi.type + ';base64,' + [Convert]::ToBase64String($pi.bytes)) }
    $subj = "$($d.subject)".Trim(); if (-not $subj) { $subj = Get-EmailSubject $id }
    Send $ctx @{ ok = $true; html = "$html"; subject = $subj.Replace('{mailbox}', 'finance@contoso.com') }
}

# Endpoint: /api/email-custom-save - saves (or removes) the custom HTML of one e-mail, and writes the activity log.
$ScreenHandlers['/api/email-custom-save'] = {
    # { id, on, html } - your own HTML for this e-mail (on = use it instead of the built-in design)
    $id = "$($d.id)"; if (-not $script:EmailDefs.Contains($id)) { throw 'Unknown e-mail.' }
    $h = "$($d.html)"; $on = [bool]$d.on
    if ($on) { if (-not $h.Trim()) { throw 'Paste the HTML first.' }; Test-EmailCustomHtml $h $id }
    $st = Get-EmailStore
    if (-not $h.Trim() -and -not $on) { $st.Remove("custom.$id") } else { $st["custom.$id"] = @{ on = "$on"; html = $h } }
    Save-EmailStore $st
    Write-ActRow 'Email messages' $(if ($on) { 'Use own HTML e-mail' } else { 'Stop using own HTML e-mail' }) $script:EmailDefs[$id].title 'Done' "$($h.Length) characters"
    Send $ctx @{ ok = $true; email = (Get-EmailView $id) }
}
# Endpoint: /api/email-img-save - saves one picture per e-mail. The old picture file is deleted; the new name contains the time so e-mail clients do not cache an old one.
$ScreenHandlers['/api/email-img-save'] = {
    # { id, data: "data:image/png;base64,..." } - one picture per e-mail
    $id = "$($d.id)"; if (-not $script:EmailDefs.Contains($id)) { throw 'Unknown e-mail.' }
    $s = "$($d.data)"; $i = $s.IndexOf('base64,'); if ($i -lt 0) { throw 'No picture received.' }
    try { $bytes = [Convert]::FromBase64String($s.Substring($i + 7)) } catch { throw 'The picture could not be read.' }
    $ext = Test-EmailPicture $bytes
    if (-not (Test-Path $script:EmailImgDir)) { New-Item -ItemType Directory -Path $script:EmailImgDir -Force | Out-Null }
    $st = @{}; $old = Get-EmailStore; foreach ($k in $old.Keys) { $st[$k] = @{} + $old[$k] }
    $lay = @{}; if ($st.ContainsKey("layout.$id")) { $lay = @{} + $st["layout.$id"] }
    if ($lay.img) { Remove-Item (Join-Path $script:EmailImgDir ([IO.Path]::GetFileName("$($lay.img)"))) -Force -ErrorAction SilentlyContinue }
    $fn = "$id-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))$ext"
    [IO.File]::WriteAllBytes((Join-Path $script:EmailImgDir $fn), $bytes)
    $lay.img = $fn; $st["layout.$id"] = $lay
    Save-EmailStore $st
    Send $ctx @{ ok = $true; email = (Get-EmailView $id) }
}
# Endpoint: /api/email-img-remove - body { id }. Deletes the picture file and its layout entry.
$ScreenHandlers['/api/email-img-remove'] = {
    $id = "$($d.id)"; if (-not $script:EmailDefs.Contains($id)) { throw 'Unknown e-mail.' }
    $st = @{}; $old = Get-EmailStore; foreach ($k in $old.Keys) { $st[$k] = @{} + $old[$k] }
    if ($st.ContainsKey("layout.$id")) {
        $lay = @{} + $st["layout.$id"]
        if ($lay.img) { Remove-Item (Join-Path $script:EmailImgDir ([IO.Path]::GetFileName("$($lay.img)"))) -Force -ErrorAction SilentlyContinue }
        $lay.Remove('img'); if ($lay.Count) { $st["layout.$id"] = $lay } else { $st.Remove("layout.$id") }
        Save-EmailStore $st
    }
    Send $ctx @{ ok = $true; email = (Get-EmailView $id) }
}

# Endpoint: /api/email-img-all - body { id }. Copies the picture (logo) of this e-mail, with its place / alignment / width, to EVERY other e-mail,
# so one logo is used everywhere (built-in layout and own HTML via {logo}). v2.9.0. Sends { ok, count, email, emails }.
$ScreenHandlers['/api/email-img-all'] = {
    $id = "$($d.id)"; if (-not $script:EmailDefs.Contains($id)) { throw 'Unknown e-mail.' }
    $src = Get-EmailImage $id; if (-not $src) { throw 'This e-mail has no picture yet. Choose a picture first.' }
    $st = @{}; $old = Get-EmailStore; foreach ($k in $old.Keys) { $st[$k] = @{} + $old[$k] }
    $srcLay = $st["layout.$id"]; $ext = [IO.Path]::GetExtension($src.name); $stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss'); $n = 0
    if (-not (Test-Path $script:EmailImgDir)) { New-Item -ItemType Directory -Path $script:EmailImgDir -Force | Out-Null }
    foreach ($oid in @($script:EmailDefs.Keys)) {
        if ($oid -eq $id) { continue }
        $lay = @{}; if ($st.ContainsKey("layout.$oid")) { $lay = @{} + $st["layout.$oid"] }
        # Delete the old picture file of that e-mail, then write a copy of this picture under a new name.
        if ($lay.img) { Remove-Item (Join-Path $script:EmailImgDir ([IO.Path]::GetFileName("$($lay.img)"))) -Force -ErrorAction SilentlyContinue }
        $fn = "$oid-$stamp$ext"; [IO.File]::WriteAllBytes((Join-Path $script:EmailImgDir $fn), $src.bytes); $lay.img = $fn
        foreach ($k in 'imgPos', 'imgAlign', 'imgW') { if ($srcLay.ContainsKey($k)) { $lay[$k] = $srcLay[$k] } else { $lay.Remove($k) } }
        $st["layout.$oid"] = $lay; $n++
    }
    Save-EmailStore $st
    Write-ActRow 'Email messages' 'Use one picture in all e-mails' $script:EmailDefs[$id].title 'Done' "$n e-mails"
    Send $ctx @{ ok = $true; count = $n; email = (Get-EmailView $id); emails = (Get-EmailAll) }
}
