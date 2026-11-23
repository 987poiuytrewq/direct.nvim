# Security policy

direct.nvim can move or delete files and can run shell commands through
`:DirectRun` and `:DirectGit`. If you discover a vulnerability that could cause
data loss or run commands or code that the user did not intend, report it
privately through GitHub's **Report a vulnerability** option on this
repository's Security tab.

Please do not disclose these reports in a public issue, discussion, pull
request, or other public channel. If private vulnerability reporting is not
available, contact the maintainer through the contact information on their
GitHub profile rather than posting details publicly.

Include the affected direct.nvim and Neovim versions, operating system, the
impact, and concise reproduction steps. Use a throwaway directory and
non-sensitive files; do not include private user data, credentials, or other
secrets. If the report involves command execution, describe the command and
conditions that trigger it without running it against data or systems you do
not own.

The maintainer will review the report, may ask for details to confirm its
impact, and will work with the reporter on an appropriate fix and disclosure.
Response and resolution times depend on the report and maintainer availability;
there is no fixed response-time guarantee. Please keep the report private while
it is being investigated.
