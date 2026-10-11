## ADDED Requirements

### Requirement: Bounded private support information
NoSleep SHALL keep at most four 256-KiB event files and retain records for at most seven days, with at most 32 queued records and 120 accepted events per minute. It SHALL export diagnostics only by explicit user action without credentials, usernames, server addresses, raw process output or system logs.

#### Scenario: Repeated observations and distinct actions
- **WHEN** repeated unchanged state is observed and the user performs repeated separate actions
- **THEN** state observations are coalesced while separate actions remain distinguishable within the rate budget

#### Scenario: Event flood and retention
- **WHEN** events exceed the queue or rate limit or old records remain in a recently modified file
- **THEN** the queue and disk budgets remain bounded and records older than seven days are removed

#### Scenario: Tampered log fields
- **WHEN** a log contains arbitrary extra fields or unstructured text
- **THEN** export re-encodes only allowed typed fields

#### Scenario: Storage failure
- **WHEN** the log directory cannot be written
- **THEN** diagnostics reports unavailable storage while power protection remains independent
