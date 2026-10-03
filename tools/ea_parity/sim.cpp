#include "sim.h"
std::string _Symbol="EURUSD"; ENUM_TIMEFRAMES _Period=PERIOD_M1; double _Point=0.00001;
std::vector<Bar> M1; long CUR=0; std::vector<Bar> TF[5];
std::vector<Deal> DEALS; Pos POS; bool PENDING=false; bool pendShort=false; double pendLots=0,pendSl=0,pendTp=0; ulong NEXTID=1;
static long days_from_civil(int y,int m,int d){ y-=m<=2; long era=(y>=0?y:y-399)/400; unsigned yoe=(unsigned)(y-era*400); unsigned doy=(153*(m+(m>2?-3:9))+2)/5+d-1; unsigned doe=yoe*365+yoe/4-yoe/100+doy; return era*146097+(long)doe-719468; }
static void civil_from_days(long z,int&y,int&m,int&d){ z+=719468; long era=(z>=0?z:z-146096)/146097; unsigned doe=(unsigned)(z-era*146097); unsigned yoe=(doe-doe/1460+doe/36524-doe/146096)/365; y=(int)(yoe)+(int)era*400; unsigned doy=doe-(365*yoe+yoe/4-yoe/100); unsigned mp=(5*doy+2)/153; d=doy-(153*mp+2)/5+1; m=mp<10?mp+3:mp-9; y+=m<=2; }
void TimeToStruct(datetime t,MqlDateTime&s){ long days=t/86400; long rem=t%86400; if(rem<0){rem+=86400;days--;} int y,m,d; civil_from_days(days,y,m,d); s.year=y;s.mon=m;s.day=d; s.hour=rem/3600; s.min=(rem%3600)/60; s.sec=rem%60; s.day_of_week=(int)(((days+4)%7+7)%7); s.day_of_year=0; }
datetime StructToTime(MqlDateTime&s){ int y=s.year,m=s.mon; while(m>12){m-=12;y++;} while(m<1){m+=12;y--;} return days_from_civil(y,m,1)*86400L+(s.day-1)*86400L+s.hour*3600L+s.min*60L+s.sec; }
const char* TimeToString(datetime t){ static char buf[8][32]; static int k=0; k=(k+1)%8; MqlDateTime s; TimeToStruct(t,s); snprintf(buf[k],32,"%04d.%02d.%02d %02d:%02d",s.year,s.mon,s.day,s.hour,s.min); return buf[k]; }
datetime TimeCurrent(){ return M1[CUR].t; }
std::string StringFormat(const char*fmt,...){ char b[1024]; va_list a; va_start(a,fmt); vsnprintf(b,1024,fmt,a); va_end(a); return b; }
void PrintFormat(const char*fmt,...){ char b[1024]; std::string f=fmt; size_t p; while((p=f.find("%I64d"))!=std::string::npos) f.replace(p,5,"%ld"); va_list a; va_start(a,fmt); vsnprintf(b,1024,f.c_str(),a); va_end(a); std::cout<<b<<"\n"; }
int tfIndex(ENUM_TIMEFRAMES tf){ switch(tf){case PERIOD_M1:return 0;case PERIOD_H1:return 0;case PERIOD_H4:return 1;case PERIOD_D1:return 2;case PERIOD_W1:return 3;default:return 4;} }
const std::vector<Bar>& series(ENUM_TIMEFRAMES tf){ return tf==PERIOD_M1?M1:TF[tfIndex(tf)]; }
int visCount(ENUM_TIMEFRAMES tf){ const std::vector<Bar>&v=series(tf); if(tf==PERIOD_M1) return (int)CUR+1; datetime now=M1[CUR].t; int lo=0,hi=(int)v.size(); while(lo<hi){int mid=(lo+hi)/2; if(v[mid].t<=now) lo=mid+1; else hi=mid;} return lo; }
datetime iTime(const std::string&,ENUM_TIMEFRAMES tf,int sh){ int vc=visCount(tf); int idx=vc-1-sh; if(sh<0||idx<0) return 0; return series(tf)[idx].t; }
double iHigh(const std::string&,ENUM_TIMEFRAMES tf,int sh){ int vc=visCount(tf); int idx=vc-1-sh; if(sh<0||idx<0) return 0; return series(tf)[idx].h; }
double iLow(const std::string&,ENUM_TIMEFRAMES tf,int sh){ int vc=visCount(tf); int idx=vc-1-sh; if(sh<0||idx<0) return 0; return series(tf)[idx].l; }
int iBarShift(const std::string&,ENUM_TIMEFRAMES tf,datetime t,bool){ const std::vector<Bar>&v=series(tf); int vc=visCount(tf); int lo=0,hi=vc; while(lo<hi){int mid=(lo+hi)/2; if(v[mid].t<=t) lo=mid+1; else hi=mid;} int idx=lo-1; if(idx<0) return -1; return vc-1-idx; }
static MqlRates toR(const Bar&b){ MqlRates r; r.time=b.t;r.open=b.o;r.high=b.h;r.low=b.l;r.close=b.c;r.tick_volume=1;r.spread=0;r.real_volume=0; return r; }
int CopyRates(const std::string&,ENUM_TIMEFRAMES tf,int start,int count,RatesArr&out){ out.clear(); const std::vector<Bar>&v=series(tf); int vc=visCount(tf); std::vector<MqlRates> tmp; for(int s=start;s<start+count;s++){ int idx=vc-1-s; if(idx<0) break; tmp.push_back(toR(v[idx])); } if(out.series){ for(auto&r:tmp) out.push_back(r);} else { for(int i=(int)tmp.size()-1;i>=0;i--) out.push_back(tmp[i]); } return (int)out.size(); }
int CopyRates(const std::string&,ENUM_TIMEFRAMES tf,datetime a,datetime b,RatesArr&out){ out.clear(); const std::vector<Bar>&v=series(tf); int vc=visCount(tf); std::vector<MqlRates> tmp; for(int i=0;i<vc;i++) if(v[i].t>=a&&v[i].t<=b) tmp.push_back(toR(v[i])); if(out.series){ for(int i=(int)tmp.size()-1;i>=0;i--) out.push_back(tmp[i]); } else for(auto&r:tmp) out.push_back(r); return (int)out.size(); }
long SymbolInfoInteger(const std::string&,int){ return 5; }
double SymbolInfoDouble(const std::string&,int p){ switch(p){case SYMBOL_TRADE_TICK_SIZE:return 0.00001;case SYMBOL_TRADE_TICK_VALUE:return 1.0;case SYMBOL_VOLUME_MIN:return 0.01;case SYMBOL_VOLUME_MAX:return 100.0;case SYMBOL_VOLUME_STEP:return 0.01;} return 0; }
double NormalizeDouble(double v,int d){ double m=std::pow(10.0,d); return std::round(v*m)/m; }
int PeriodSeconds(ENUM_TIMEFRAMES tf){ return (int)tf*60; }
int PositionsTotal(){ return POS.open?1:0; } ulong PositionGetTicket(int){ return POS.id; } bool PositionSelectByTicket(ulong){ return POS.open; } long PositionGetInteger(int){ return 20260902; }
bool HistorySelect(datetime,datetime){ return true; } int HistoryDealsTotal(){ return (int)DEALS.size(); } ulong HistoryDealGetTicket(int i){ return DEALS[i].ticket; }
long HistoryDealGetInteger(ulong t,int p){ const Deal&d=DEALS[t-1]; switch(p){case DEAL_MAGIC:return d.magic;case DEAL_ENTRY:return d.entry;case DEAL_TIME:return d.time;case DEAL_POSITION_ID:return d.pid;case DEAL_TYPE:return d.type;} return 0; }
double HistoryDealGetDouble(ulong t,int p){ const Deal&d=DEALS[t-1]; switch(p){case DEAL_PROFIT:return d.profit;case DEAL_COMMISSION:return d.commission;case DEAL_FEE:return d.fee;} return 0; }
std::string HistoryDealGetString(ulong,int){ return "EURUSD"; }

long OBJ_COUNT=0, OBJ_REBUILDS=0;
long MQLInfoInteger(int p){ return p==MQL_VISUAL_MODE?1:0; }
int iHighest(const std::string&,ENUM_TIMEFRAMES tf,int,int cnt,int start){ const std::vector<Bar>&v=series(tf); int vc=visCount(tf); int best=-1; double bv=-1e18; for(int s=start;s<start+cnt;s++){ int idx=vc-1-s; if(idx<0) break; if(v[idx].h>bv){bv=v[idx].h;best=s;} } return best; }
int iLowest(const std::string&,ENUM_TIMEFRAMES tf,int,int cnt,int start){ const std::vector<Bar>&v=series(tf); int vc=visCount(tf); int best=-1; double bv=1e18; for(int s=start;s<start+cnt;s++){ int idx=vc-1-s; if(idx<0) break; if(v[idx].l<bv){bv=v[idx].l;best=s;} } return best; }
int ObjectFind(long,const std::string&){ return -1; } bool ObjectDelete(long,const std::string&){ return true; }
bool ObjectCreate(long,const std::string&,int,int,datetime,double,datetime,double){ OBJ_COUNT++; return true; }
bool ObjectSetInteger(long,const std::string&,int,long){ return true; } int ObjectsDeleteAll(long,const std::string&){ OBJ_REBUILDS++; return 0; }
std::string DoubleToString(double v,int d){ char b[64]; snprintf(b,64,"%.*f",d,v); return b; } std::string IntegerToString(long v){ return std::to_string(v); }
