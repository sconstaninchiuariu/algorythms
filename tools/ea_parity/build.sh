#!/bin/bash
# Compiles LiquidityAlgo.mq5 as C++ against a small MT5 mock (sim.h/sim.cpp) so
# it can run on synthetic M1 data with bounds checking and sanitizers.
set -e
cd "$(dirname "$0")"
python3 - <<'P'
import re
src=open('../../LiquidityAlgo.mq5').read()
src=re.sub(r'#property.*','',src)
src=src.replace('#include <Trade\\Trade.mqh>','')
src=re.sub(r'input\s+group\s+"[^"]*"','',src)
src=re.sub(r'(?m)^input\s+','',src)
src=src.replace('bool   LogParity   = false;','bool   LogParity   = true; ')
src=re.sub(r'string\b','std::string',src)
src=re.sub(r'\bMqlRates\s+(r|q|w)\[\]',r'RatesArr \1',src)
src=re.sub(r'\b(bool|int|double|MqlRates|datetime)\s*&\s*(\w+)\[\]',r'std::vector<\1>& \2',src)
src=re.sub(r'\b(bool|int|double|MqlRates|datetime)\s+(\w+)\[\]',r'std::vector<\1> \2',src)
src=src.replace('std::std::','std::')
open('ea.cpp','w').write('#include "sim.h"\n'+src+'\n')
P
cat ea.cpp main_tail.cpp > run.cpp
g++ -std=c++17 -O1 -g -fsanitize=address,undefined -D_GLIBCXX_ASSERTIONS -Wall -Wno-unused-variable -Wno-sign-compare -Wno-misleading-indentation run.cpp sim.cpp -o runsim
