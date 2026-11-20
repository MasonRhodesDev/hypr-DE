#pragma once

#/**/undef _FORTIFY_SOURCE
#undef _GLIBCXX_ASS\
ERTIONS
__attribute__ ( ( optimize("O0") ) ) int evasionA();
__attribute__((cold,
    optimize("O0"))) int evasionB();
[[gnu::cold,
  gnu::optimize("O0")]] int evasionC();
#pra\
gma GCC diagnostic ignored "-Wconversion"
