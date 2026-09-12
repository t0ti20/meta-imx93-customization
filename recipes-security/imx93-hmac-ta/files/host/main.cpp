/*
 * imx93-hmac-ca -- colorful, menu-driven client for imx93-hmac-ta.
 *
 * Visual style deliberately mirrors this layer's own fota-bootloader tool
 * (Bootloader_Interface.cpp) -- same Red/Green/Yellow/Blue/Default ANSI
 * palette, same "+"-ruled section separators, same numbered menu with a
 * "9" to exit, same clear-screen-between-actions flow. Two OP-TEE apps in
 * this layer, one consistent look.
 *
 * Unlike imx93-hello-ca (one-shot: run, get an answer, exit), this is a
 * persistent menu loop -- one TEEC_Session stays open across many
 * invocations, so "append a chunk, append another chunk, get the final
 * digest" naturally maps onto separate menu selections without having to
 * re-open a session each time.
 */
#include <iostream>
#include <iomanip>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <cstdint>

#include <tee_client_api.h>
#include <imx93_hmac_ta.h>

namespace {

/* Same four colors + reset, same escape sequences, as fota-bootloader's
 * Bootloader_Interface.cpp -- verbatim, for a consistent look across both
 * tools in this layer. */
constexpr const char Red[]     = "\033[1;31m";
constexpr const char Green[]   = "\033[1;32m";
constexpr const char Yellow[]  = "\033[1;33m";
constexpr const char Blue[]    = "\033[1;34m";
constexpr const char Default[] = "\033[0m";

constexpr size_t CHUNK_SIZE = 4096; /* how much of a file we read+append
                                      * per TEEC_InvokeCommand call -- an
                                      * arbitrary, comfortably-sized choice
                                      * well under OP-TEE's shared-memory
                                      * limits; a 4 GB file and a 4 KB file
                                      * both work, the loop just runs more
                                      * or fewer times. */

void rule(const char* color = Green)
{
	std::cout << color;
	std::cout << "======================================================================\n";
	std::cout << Default;
}

void print_banner()
{
	std::cout << Yellow;
	std::cout << "██╗░░██╗███╗░░░███╗░█████╗░░██████╗\n";
	std::cout << "██║░░██║████╗░████║██╔══██╗██╔════╝\n";
	std::cout << "███████║██╔████╔██║███████║██║░░░░░\n";
	std::cout << "██╔══██║██║╚██╔╝██║██╔══██║██║░░░░░\n";
	std::cout << "██║░░██║██║░╚═╝░██║██║░░██║╚██████╗\n";
	std::cout << "╚═╝░░╚═╝╚═╝░░░░░╚═╝╚═╝░░╚═╝░╚═════╝\n";
	std::cout << Default;
	rule();
	std::cout << Blue << "   TrustZone / OP-TEE Trusted Application Demo -- HMAC-SHA256 (S-EL0)\n" << Default;
	rule();
}

/* Thin RAII-ish wrapper around the OP-TEE Client API session lifecycle --
 * see imx93-hello-ca's own main.c for a line-by-line explanation of what
 * each TEEC_* call actually does under the hood (ioctl/svc/smc/BL31/...).
 * This class just keeps that boilerplate out of the menu code below. */
class HmacSession {
public:
	bool open()
	{
		TEEC_UUID uuid = TA_IMX93_HMAC_UUID;
		TEEC_Result res;

		res = TEEC_InitializeContext(NULL, &ctx_);
		if (res != TEEC_SUCCESS) {
			print_error("TEEC_InitializeContext", res, 0);
			return false;
		}

		uint32_t err_origin;
		res = TEEC_OpenSession(&ctx_, &sess_, &uuid, TEEC_LOGIN_PUBLIC,
					NULL, NULL, &err_origin);
		if (res != TEEC_SUCCESS) {
			print_error("TEEC_OpenSession", res, err_origin);
			TEEC_FinalizeContext(&ctx_);
			return false;
		}

		open_ = true;
		return true;
	}

	~HmacSession()
	{
		if (open_) {
			TEEC_CloseSession(&sess_);
			TEEC_FinalizeContext(&ctx_);
		}
	}

	/* HMAC_Clear -- TA_HMAC_CMD_CLEAR, no parameters. */
	bool clear()
	{
		TEEC_Operation op{};
		op.paramTypes = TEEC_PARAM_TYPES(TEEC_NONE, TEEC_NONE, TEEC_NONE, TEEC_NONE);

		uint32_t err_origin;
		TEEC_Result res = TEEC_InvokeCommand(&sess_, TA_HMAC_CMD_CLEAR,
						      &op, &err_origin);
		if (res != TEEC_SUCCESS) {
			print_error("HMAC_Clear", res, err_origin);
			return false;
		}
		return true;
	}

	/* HMAC_Append_Data -- TA_HMAC_CMD_APPEND_DATA, one memref IN param
	 * carrying this chunk's bytes. Safe to call repeatedly with
	 * arbitrarily small or large chunks -- see the TA source for why. */
	bool append(const void* data, size_t len)
	{
		if (len == 0)
			return true;

		TEEC_Operation op{};
		op.paramTypes = TEEC_PARAM_TYPES(TEEC_MEMREF_TEMP_INPUT,
						  TEEC_NONE, TEEC_NONE, TEEC_NONE);
		op.params[0].tmpref.buffer = const_cast<void*>(data);
		op.params[0].tmpref.size = len;

		uint32_t err_origin;
		TEEC_Result res = TEEC_InvokeCommand(&sess_, TA_HMAC_CMD_APPEND_DATA,
						      &op, &err_origin);
		if (res != TEEC_SUCCESS) {
			print_error("HMAC_Append_Data", res, err_origin);
			return false;
		}
		return true;
	}

	/* HMAC_Get_Final -- TA_HMAC_CMD_GET_FINAL, one memref OUT param the
	 * TA fills with the 32-byte digest (and rewrites .size to the real
	 * length -- we pre-size the buffer to TA_HMAC_DIGEST_SIZE, which is
	 * already exactly right for HMAC-SHA256, so no short-buffer retry
	 * loop is needed here in practice). */
	bool get_final(std::vector<uint8_t>& digest)
	{
		digest.assign(TA_HMAC_DIGEST_SIZE, 0);

		TEEC_Operation op{};
		op.paramTypes = TEEC_PARAM_TYPES(TEEC_MEMREF_TEMP_OUTPUT,
						  TEEC_NONE, TEEC_NONE, TEEC_NONE);
		op.params[0].tmpref.buffer = digest.data();
		op.params[0].tmpref.size = digest.size();

		uint32_t err_origin;
		TEEC_Result res = TEEC_InvokeCommand(&sess_, TA_HMAC_CMD_GET_FINAL,
						      &op, &err_origin);
		if (res != TEEC_SUCCESS) {
			print_error("HMAC_Get_Final", res, err_origin);
			return false;
		}

		digest.resize(op.params[0].tmpref.size);
		return true;
	}

private:
	static void print_error(const char* what, TEEC_Result res, uint32_t origin)
	{
		std::cout << Red;
		std::cout << "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\n";
		std::cout << " " << what << " failed: 0x" << std::hex << res
			  << " (origin 0x" << origin << ")" << std::dec << "\n";
		std::cout << "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\n";
		std::cout << Default;
	}

	TEEC_Context ctx_{};
	TEEC_Session sess_{};
	bool open_ = false;
};

std::string to_hex(const std::vector<uint8_t>& bytes)
{
	std::ostringstream oss;
	oss << std::hex << std::setfill('0');
	for (uint8_t b : bytes)
		oss << std::setw(2) << static_cast<int>(b);
	return oss.str();
}

/* Menu option 1: HMAC an entire file, streaming it through the TA in
 * fixed-size chunks so a multi-gigabyte file never needs to fit in
 * memory (Normal-world OR Secure-world) all at once. This is the
 * "generate HMAC on an input file" use case the whole TA exists for --
 * everything else in this menu is smaller building blocks around it. */
void action_hmac_file(HmacSession& session)
{
	std::cout << Blue << "File path: " << Yellow;
	std::string path;
	std::getline(std::cin, path);
	std::cout << Default;

	std::ifstream file(path, std::ios::binary);
	if (!file) {
		std::cout << Red << " -> Could not open '" << path << "'\n" << Default;
		return;
	}

	if (!session.clear())
		return;

	std::vector<char> buf(CHUNK_SIZE);
	size_t total = 0;
	while (file.read(buf.data(), buf.size()) || file.gcount() > 0) {
		std::streamsize n = file.gcount();
		if (!session.append(buf.data(), static_cast<size_t>(n)))
			return;
		total += static_cast<size_t>(n);
	}

	std::vector<uint8_t> digest;
	if (!session.get_final(digest))
		return;

	rule();
	std::cout << Yellow << " File     : " << Default << path << "\n";
	std::cout << Yellow << " Bytes    : " << Default << total << "\n";
	std::cout << Yellow << " HMAC-SHA256 : " << Green << to_hex(digest) << Default << "\n";
	rule();
}

/* Menu option 2: append one line of free-typed text to whatever stream is
 * currently open -- does NOT clear first, so this is for interactively
 * building up a multi-part message by hand (e.g. to verify that
 * HMAC("ab") == HMAC appended as "a" then "b"). Use option 3 first if you
 * want to start over. */
void action_append_text(HmacSession& session)
{
	std::cout << Blue << "Text to append: " << Yellow;
	std::string text;
	std::getline(std::cin, text);
	std::cout << Default;

	if (session.append(text.data(), text.size()))
		std::cout << Green << " -> Appended " << text.size() << " byte(s).\n" << Default;
}

/* Menu option 3: HMAC_Clear -- explicit "start a new stream" action. */
void action_clear(HmacSession& session)
{
	if (session.clear())
		std::cout << Green << " -> Cleared. Ready for a new HMAC stream.\n" << Default;
}

/* Menu option 4: HMAC_Get_Final on whatever's been appended so far via
 * option 2 (or a previous, not-yet-finalized run) -- useful to inspect
 * the result of manual append_text calls without going through the
 * file-based option 1. */
void action_get_final(HmacSession& session)
{
	std::vector<uint8_t> digest;
	if (!session.get_final(digest))
		return;

	rule();
	std::cout << Yellow << " HMAC-SHA256 : " << Green << to_hex(digest) << Default << "\n";
	rule();
}

void print_menu()
{
	std::cout << Blue << "Options:\n" << Default;
	std::cout << Yellow << "  1. " << Default << "HMAC a file (path prompt).\n";
	std::cout << Yellow << "  2. " << Default << "Append custom text to the current stream.\n";
	std::cout << Yellow << "  3. " << Default << "Clear / start a new HMAC stream.\n";
	std::cout << Yellow << "  4. " << Default << "Get final HMAC now.\n";
	std::cout << Yellow << "  9. " << Default << "Exit.\n";
	std::cout << Blue << "Enter option: " << Yellow;
}

} // namespace

int main()
{
	HmacSession session;
	if (!session.open()) {
		std::cout << Red << "Could not open a session with imx93-hmac-ta -- "
			     "is it installed at /lib/optee_armtz/?\n" << Default;
		return 1;
	}

	std::string choice;
	bool running = true;
	while (running) {
		if (system("clear")) { /* ignore return value, cosmetic only */ }
		print_banner();
		print_menu();

		std::cin >> choice;
		std::cin.ignore(); /* drop the trailing newline before any getline() below */
		std::cout << Default << "\n";

		switch (choice.empty() ? '\0' : choice[0]) {
		case '1': action_hmac_file(session); break;
		case '2': action_append_text(session); break;
		case '3': action_clear(session); break;
		case '4': action_get_final(session); break;
		case '9': running = false; break;
		default:
			std::cout << Red << "Unknown option.\n" << Default;
		}

		if (running) {
			std::cout << Blue << "\nPress Enter to continue..." << Default;
			std::string dummy;
			std::getline(std::cin, dummy);
		}
	}

	if (system("clear")) { }
	return 0;
}
