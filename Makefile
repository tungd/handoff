# Makefile for agentctl
# Builds release binaries for arm64, x86_64, and universal

.PHONY: release arm64 x86_64 universal clean install

# Default target: build all three binaries
release: arm64 x86_64 universal

# Build for Apple Silicon (arm64)
arm64:
	swift build -c release --arch arm64

# Build for Intel (x86_64)
x86_64:
	swift build -c release --arch x86_64

# Build universal binary (combines arm64 + x86_64)
universal: arm64 x86_64
	@mkdir -p .build/universal
	lipo -create \
		.build/arm64-apple-macosx/release/agentctl \
		.build/x86_64-apple-macosx/release/agentctl \
		-output .build/universal/agentctl
	@echo "Universal binary created at .build/universal/agentctl"
	@lipo -info .build/universal/agentctl

# Install the universal binary to /usr/local/bin
install: universal
	install -m 755 .build/universal/agentctl /usr/local/bin/agentctl
	@echo "Installed agentctl to /usr/local/bin/agentctl"

# Clean build artifacts
clean:
	swift package clean
	rm -rf .build/universal
	@echo "Build artifacts cleaned"