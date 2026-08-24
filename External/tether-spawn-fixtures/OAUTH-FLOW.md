# OAuth flow

User steps for the integrator:

1. Run the CLI login command.
2. The CLI detects the browser environment and sends the opener spawn request.
3. The browser opens the full Claude OAuth authorize URL.
4. Complete authorization, then paste the displayed code into the CLI.
5. The CLI reports success.

This document describes the integration flow only; this fixture pack does not implement an in-app browser.
