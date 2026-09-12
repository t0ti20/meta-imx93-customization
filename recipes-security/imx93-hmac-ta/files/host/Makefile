# Normal-World (EL0) client build -- plain C++ cross-compile, same
# --sysroot-driven pattern as imx93-hello-ca's own host/Makefile (see that
# file's comments for the full explanation of why CXX/CXXFLAGS/LDFLAGS are
# passed in from the recipe rather than hardcoded here).
CXX ?= g++
BINARY = imx93-hmac-ca

.PHONY: all
all: $(BINARY)

# -std=c++17: for structured-enough modern C++ (std::vector, range-based
# constructs) without requiring anything newer than what this BSP's
# toolchain (gcc 13.x) comfortably supports.
# -I../ta/include: same reasoning as imx93-hello-ca -- only the shared
# UUID/command-ID header lives there, not any TA implementation code.
$(BINARY): main.cpp
	$(CXX) $(CXXFLAGS) -std=c++17 -I../ta/include -o $@ $< $(LDFLAGS) -lteec

.PHONY: clean
clean:
	rm -f $(BINARY)
