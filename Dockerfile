# Simple single-stage image for Kubernetes deployments
FROM public.ecr.aws/docker/library/ubuntu:22.04

# Install only what we need: bash and ldap-utils
RUN apt-get update && \
    apt-get install -y ldap-utils bash && \
    rm -rf /var/lib/apt/lists/*

# Copy the simple all-in-one resolver script
COPY resolve-simple.sh /usr/local/bin/resolve-owners
RUN chmod +x /usr/local/bin/resolve-owners

# Default entrypoint
ENTRYPOINT ["/usr/local/bin/resolve-owners"]