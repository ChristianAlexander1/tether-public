# Physical-device release pass

Record device model, iOS version, app version/build, commit, tester and date.

## Required checks

- Add an On My iPhone folder; read, create, rename and delete a test file.
- Force-quit and relaunch; confirm the bookmark reopens without another picker.
- Repeat workspace open/close 100 times and confirm security-scope access stays balanced.
- Repeat with an iCloud folder containing an evicted file and confirm download/read succeeds.
- Install unrelated packages in one session: Git, Python, ripgrep and build-base.
- Run a pipeline, a background job, Ctrl-C on `sleep 30`, then another command.
- Run Node with redirected output and confirm the file contains only requested bytes.
- Open a generic HTTPS URL from Alpine and from Node.
- Complete real Claude account login, exit with double Ctrl-C, and start it again.
- Create/edit a workspace file from the CLI and inspect it in Files.
- Change terminal font size, rotate the device, use hardware/software keyboards,
  paste at least 10 KB and exercise VoiceOver labels on app chrome.
- Observe memory during package installation, Node/Claude use and terminal flood;
  confirm no jetsam termination or unbounded growth.
- Verify the Licenses and Storage screens match the archived build.

## Result

Do not mark this gate complete without a signed-device run. Record failures and
links to logs/screenshots with the release evidence.
