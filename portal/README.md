# Portal

This directory contains the static Ninth Dimension landing page and its
branding assets.

The Compose configuration mounts this directory into the portal web server.
Keep `index.html`, the favicon files, and the logo/header assets referenced by
the page together.

The application links are built dynamically from the hostname and protocol
used to open the portal:
- AI Assistant: port 3000
- Document Ingester — RAG: port 8098

Avoid hard-coding a server IP address into the HTML.
