FROM fukamachi/roswell:22.04

# Install the system and its local dependencies into the image
# so ql:quickload is instant at runtime.

WORKDIR /app

# Copy the system files
COPY monitor-sites.asd monitor-sites-package.lisp monitor-sites.lisp ./
COPY eval-safely.lisp ./
COPY monitor-sites ./

# Local projects that monitor-sites depends on (not on Quicklisp)
# Uncomment and adjust if you need to bundle them:
# COPY dc-eclectic/ /app/local-projects/dc-eclectic/
# COPY dc-time/ /app/local-projects/dc-time/
# COPY p-log/ /app/local-projects/p-log/

# Register local projects and pre-load all dependencies
RUN ros config
RUN ql:quickload :monitor-sites

# Set the entrypoint
RUN chmod +x /app/monitor-sites
ENTRYPOINT ["/app/monitor-sites", "start"]
