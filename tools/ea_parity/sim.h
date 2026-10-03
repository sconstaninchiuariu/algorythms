#include <vector>
#include <string>
#include <cmath>
#include <cstdio>
#include <cstdarg>
#include <cstdlib>
#include <iostream>
#include <algorithm>
typedef long datetime; typedef unsigned long ulong;
struct MqlDateTime { int year,mon,day,hour,min,sec,day_of_week,day_of_year; };
struct MqlRates { datetime time; double open,high,low,close; long tick_volume; int spread; long real_volume; };
struct RatesArr : std::vector<MqlRates> { bool series=false; };
enum ENUM_TIMEFRAMES { PERIOD_M1=1, PERIOD_H1=60, PERIOD_H4=240, PERIOD_D1=1440, PERIOD_W1=10080, PERIOD_MN1=43200 };
enum { POSITION_MAGIC=1, DEAL_MAGIC=2, DEAL_ENTRY=3, DEAL_TIME=4, DEAL_POSITION_ID=5, DEAL_TYPE=6, DEAL_PROFIT=7, DEAL_COMMISSION=8, DEAL_FEE=9, DEAL_SYMBOL=10,
 DEAL_ENTRY_IN=0, DEAL_ENTRY_OUT=1, DEAL_ENTRY_OUT_BY=2, DEAL_ENTRY_INOUT=3, DEAL_TYPE_BUY=0, DEAL_TYPE_SELL=1,
 SYMBOL_TRADE_TICK_SIZE=1, SYMBOL_TRADE_TICK_VALUE=2, SYMBOL_VOLUME_MIN=3, SYMBOL_VOLUME_MAX=4, SYMBOL_VOLUME_STEP=5, SYMBOL_DIGITS=6, INIT_SUCCEEDED=0, INIT_PARAMETERS_INCORRECT=1 };
typedef int color; enum ENUM_LINE_STYLE { STYLE_SOLID=0, STYLE_DOT=2 };
enum { clrWhite=0xFFFFFF, clrDimGray=0x696969, OBJ_TREND=1, OBJPROP_COLOR=1, OBJPROP_STYLE=2, OBJPROP_WIDTH=3, OBJPROP_RAY_RIGHT=4, OBJPROP_RAY_LEFT=5, OBJPROP_SELECTABLE=6, OBJPROP_BACK=7, MODE_HIGH=1, MODE_LOW=2, MQL_VISUAL_MODE=1, MQL_TESTER=2 };
extern long OBJ_COUNT, OBJ_REBUILDS;
long MQLInfoInteger(int);
int iHighest(const std::string&,ENUM_TIMEFRAMES,int,int,int); int iLowest(const std::string&,ENUM_TIMEFRAMES,int,int,int);
int ObjectFind(long,const std::string&); bool ObjectDelete(long,const std::string&); bool ObjectCreate(long,const std::string&,int,int,datetime,double,datetime,double);
bool ObjectSetInteger(long,const std::string&,int,long); int ObjectsDeleteAll(long,const std::string&);
template<class...A> void Comment(A...){}
std::string DoubleToString(double,int); std::string IntegerToString(long);
extern std::string _Symbol; extern ENUM_TIMEFRAMES _Period; extern double _Point;
// ---- market data ----
struct Bar { datetime t; double o,h,l,c; };
extern std::vector<Bar> M1; extern long CUR;   // CUR = index of the forming M1 bar
extern std::vector<Bar> TF[5];
int tfIndex(ENUM_TIMEFRAMES tf);
int visCount(ENUM_TIMEFRAMES tf);
const std::vector<Bar>& series(ENUM_TIMEFRAMES tf);
template<class T> int ArraySize(const std::vector<T>&v){return (int)v.size();}
template<class T> int ArrayResize(std::vector<T>&v,int n){v.resize(n);return n;}
template<class T> void ArraySetAsSeries(std::vector<T>&,bool){}
inline void ArraySetAsSeries(RatesArr&a,bool s){a.series=s;}
int CopyRates(const std::string&,ENUM_TIMEFRAMES,int,int,RatesArr&);
int CopyRates(const std::string&,ENUM_TIMEFRAMES,datetime,datetime,RatesArr&);
datetime iTime(const std::string&,ENUM_TIMEFRAMES,int); double iHigh(const std::string&,ENUM_TIMEFRAMES,int); double iLow(const std::string&,ENUM_TIMEFRAMES,int);
int iBarShift(const std::string&,ENUM_TIMEFRAMES,datetime,bool);
void TimeToStruct(datetime,MqlDateTime&); datetime StructToTime(MqlDateTime&); const char* TimeToString(datetime); datetime TimeCurrent();
std::string StringFormat(const char*fmt,...);
template<class...A> void Print(A... a){ ((std::cout<<a),...); std::cout<<"\n"; }
void PrintFormat(const char*fmt,...);
long SymbolInfoInteger(const std::string&,int); double SymbolInfoDouble(const std::string&,int);
double NormalizeDouble(double,int); int PeriodSeconds(ENUM_TIMEFRAMES);
inline double MathMax(double a,double b){return a>b?a:b;} inline double MathMin(double a,double b){return a<b?a:b;} inline int MathMax(int a,int b){return a>b?a:b;} inline int MathMin(int a,int b){return a<b?a:b;}
inline double MathAbs(double a){return std::fabs(a);} inline double MathFloor(double a){return std::floor(a);}
// ---- trading engine ----
struct Deal { ulong ticket; long magic; long entry; datetime time; long pid; long type; double profit,commission,fee; std::string sym; };
struct Pos { ulong id; bool isShort; double lots, entry, sl, tp; datetime openT; bool open=false; };
extern std::vector<Deal> DEALS; extern Pos POS; extern bool PENDING; extern bool pendShort; extern double pendLots,pendSl,pendTp; extern ulong NEXTID;
struct CTrade { long ResultRetcode(){return 0;} std::string ResultRetcodeDescription(){return "";} void SetExpertMagicNumber(ulong){} void SetTypeFillingBySymbol(const std::string&){}
  bool Sell(double l,const std::string&,double,double sl,double tp,const std::string&){PENDING=true;pendShort=true;pendLots=l;pendSl=sl;pendTp=tp;return true;}
  bool Buy(double l,const std::string&,double,double sl,double tp,const std::string&){PENDING=true;pendShort=false;pendLots=l;pendSl=sl;pendTp=tp;return true;} };
int PositionsTotal(); ulong PositionGetTicket(int); bool PositionSelectByTicket(ulong); long PositionGetInteger(int);
bool HistorySelect(datetime,datetime); int HistoryDealsTotal(); ulong HistoryDealGetTicket(int); long HistoryDealGetInteger(ulong,int); double HistoryDealGetDouble(ulong,int); std::string HistoryDealGetString(ulong,int);
