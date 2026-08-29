#pragma once

#include <iostream>
#include <string>

namespace imx93 {

inline void print_hello(const std::string& board = "NXP i.MX93 FRDM")
{
    std::cout << "Hello World from " << board << "! :)" << std::endl;
}

} // namespace imx93
