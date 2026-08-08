#include "remote_bitbang.hpp"

#include <arpa/inet.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <poll.h>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include <utility>

#include "dut.hpp"
#include "soc_testbench.hpp"

namespace {

constexpr unsigned JTAG_CYCLES = 2;
constexpr unsigned IDLE_CYCLES = 64;

class Socket {
  public:
    explicit Socket(int fd) : fd_(fd) {}
    ~Socket() {
        if (fd_ >= 0) {
            close(fd_);
        }
    }

    Socket(const Socket&) = delete;
    Socket& operator=(const Socket&) = delete;
    Socket(Socket&& other) noexcept : fd_(std::exchange(other.fd_, -1)) {}

    int get() const { return fd_; }

  private:
    int fd_;
};

void fail(const char* operation) {
    throw std::runtime_error(std::string(operation) + ": " +
                             std::strerror(errno));
}

Socket listen_on(uint16_t port) {
    Socket listener(socket(AF_INET, SOCK_STREAM, 0));

    if (listener.get() < 0) {
        fail("cannot create remote-bitbang socket");
    }

    int reuse = 1;
    if (setsockopt(listener.get(), SOL_SOCKET, SO_REUSEADDR,
                   &reuse, sizeof(reuse)) < 0) {
        fail("cannot configure remote-bitbang socket");
    }

    sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(listener.get(), reinterpret_cast<sockaddr*>(&address),
             sizeof(address)) < 0) {
        fail("cannot bind remote-bitbang socket");
    }

    if (listen(listener.get(), 1) < 0) {
        fail("cannot listen on remote-bitbang socket");
    }

    return listener;
}

void send_all(int fd, const std::string& data) {
    size_t offset = 0;

    while (offset < data.size()) {
        ssize_t sent = send(fd, data.data() + offset,
                            data.size() - offset, MSG_NOSIGNAL);

        if (sent < 0 && errno == EINTR) {
            continue;
        }

        if (sent <= 0) {
            fail("remote-bitbang send failed");
        }

        offset += size_t(sent);
    }
}

bool input_ready(int fd) {
    pollfd socket = {fd, POLLIN, 0};
    int ready;

    do {
        ready = poll(&socket, 1, 0);
    } while (ready < 0 && errno == EINTR);

    if (ready < 0) {
        fail("remote-bitbang poll failed");
    }

    return ready != 0;
}

}  // namespace

RemoteBitbang::RemoteBitbang(SocTestbench& testbench)
    : testbench_(testbench), top_(testbench.top()) {}

void RemoteBitbang::set_pins(char command) {
    unsigned pins = unsigned(command - '0');

    top_.i_jtag_tck = (pins >> 2) & 1;
    top_.i_jtag_tms = (pins >> 1) & 1;
    top_.i_jtag_tdi = pins & 1;
    testbench_.run_cycles(JTAG_CYCLES);
}

void RemoteBitbang::reset(char command) {
    bool system_reset = command == 's' || command == 'u';

    top_.i_rstn = !system_reset;
    testbench_.run_cycles(JTAG_CYCLES);
}

void RemoteBitbang::serve(uint16_t port) {
    Socket listener = listen_on(port);

    std::printf("remote-bitbang listening on 127.0.0.1:%u\n", port);
    std::fflush(stdout);

    while (!input_ready(listener.get())) {
        testbench_.run_cycles(IDLE_CYCLES);
    }

    Socket client(accept(listener.get(), nullptr, nullptr));

    if (client.get() < 0) {
        fail("cannot accept remote-bitbang connection");
    }

    std::puts("remote-bitbang client connected");
    std::fflush(stdout);

    char commands[4096];

    while (true) {
        if (!input_ready(client.get())) {
            testbench_.run_cycles(IDLE_CYCLES);
            continue;
        }

        ssize_t count = recv(client.get(), commands, sizeof(commands), 0);

        if (count < 0 && errno == EINTR) {
            continue;
        }

        if (count < 0) {
            fail("remote-bitbang receive failed");
        }

        if (count == 0) {
            return;
        }

        std::string response;

        for (ssize_t i = 0; i < count; ++i) {
            char command = commands[i];

            if (command >= '0' && command <= '7') {
                set_pins(command);
            } else if (command == 'R') {
                response.push_back(top_.o_jtag_tdo ? '1' : '0');
            } else if (command >= 'r' && command <= 'u') {
                reset(command);
            } else if (command == 'Q') {
                send_all(client.get(), response);
                return;
            } else if (command != 'B' && command != 'b') {
                throw std::runtime_error("unsupported remote-bitbang command");
            }
        }

        send_all(client.get(), response);
    }
}
