#!/bin/sh
# Example post-install hook payload, invoked by the 'run' directive in
# bundle.conf after the application stacks are up.
echo "setup.sh ran at $(date)" > /opt/app/setup-ran.txt
