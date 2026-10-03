#include <random>
static long keyTF(int i,datetime t){ long days=t/86400; switch(i){ case 0:return t/3600; case 1:return t/14400; case 2:return days; case 3:{ long dow=((days+4)%7+7)%7; return (days-dow); } default:{ MqlDateTime s; TimeToStruct(t,s); return s.year*12+s.mon; } } }
static datetime openOf(int i,long key){ switch(i){case 0:return key*3600; case 1:return key*14400; case 2:return key*86400; case 3:return key*86400; default:{ int y=(int)(key/12), m=(int)(key%12); if(m==0){m=12;y--;} MqlDateTime s; s.year=y;s.mon=m;s.day=1;s.hour=0;s.min=0;s.sec=0;s.day_of_week=0;s.day_of_year=0; return StructToTime(s);} } }
static void gen(unsigned seed){
  std::mt19937 rng(seed); std::normal_distribution<double> nd(0,1);
  MqlDateTime s; s.year=2025;s.mon=10;s.day=6;s.hour=0;s.min=0;s.sec=0;s.day_of_week=0;s.day_of_year=0; datetime t0=StructToTime(s);
  double p=1.1500, trend=0, vol=1.0;
  for(int w=0; w<26; w++) for(int d=0; d<5; d++) for(int m=0;m<1440;m++){
    datetime t=t0+(long)w*7*86400+(long)d*86400+(long)m*60; int hh=m/60;
    double sess=(hh>=9&&hh<17)?1.8:((hh>=0&&hh<8)?0.7:1.0);
    if(m%90==0) trend=nd(rng)*0.00002; if(m%240==0) vol=0.6+std::fabs(nd(rng))*0.9;
    double o=p; double ret=trend+nd(rng)*0.00005*vol*sess; double c=std::round((o+ret)*1e5)/1e5;
    double h=std::max(o,c)+std::fabs(nd(rng))*0.00003*vol*sess, l=std::min(o,c)-std::fabs(nd(rng))*0.00003*vol*sess;
    h=std::round(h*1e5)/1e5; l=std::round(l*1e5)/1e5; M1.push_back({t,o,h,l,c}); p=c; }
}
static void agg(){ for(int i=0;i<5;i++){ TF[i].clear(); long lastKey=-1; for(auto&b:M1){ long k=keyTF(i,b.t); if(k!=lastKey){ TF[i].push_back({openOf(i,k),b.o,b.h,b.l,b.c}); lastKey=k; } else { Bar&x=TF[i].back(); x.h=std::max(x.h,b.h); x.l=std::min(x.l,b.l); x.c=b.c; } } } }
static void engine_bar(long k){
  const Bar&b=M1[k];
  if(PENDING){ POS.open=true; POS.id=NEXTID; POS.isShort=pendShort; POS.lots=pendLots; POS.entry=b.o; POS.sl=pendSl; POS.tp=pendTp; POS.openT=b.t; PENDING=false;
     Deal d; d.ticket=DEALS.size()+1; d.magic=20260902; d.entry=DEAL_ENTRY_IN; d.time=b.t; d.pid=NEXTID; d.type=pendShort?DEAL_TYPE_SELL:DEAL_TYPE_BUY; d.profit=0; d.commission=-0.0; d.fee=0; d.sym="EURUSD"; DEALS.push_back(d); NEXTID++; }
  if(POS.open){ bool hitSl=POS.isShort?(b.h>=POS.sl):(b.l<=POS.sl); bool hitTp=POS.isShort?(b.l<=POS.tp):(b.h>=POS.tp); if(hitSl||hitTp){ double ex=hitSl?POS.sl:POS.tp; double pr=(POS.isShort?(POS.entry-ex):(ex-POS.entry))*POS.lots*100000.0;
     Deal d; d.ticket=DEALS.size()+1; d.magic=20260902; d.entry=DEAL_ENTRY_OUT; d.time=b.t+30; d.pid=POS.id; d.type=POS.isShort?DEAL_TYPE_BUY:DEAL_TYPE_SELL; d.profit=pr; d.commission=0; d.fee=0; d.sym="EURUSD"; DEALS.push_back(d); POS.open=false; } }
}
int main(int argc,char**argv){ unsigned seed=argc>1?atoi(argv[1]):1; gen(seed); agg(); if(argc>2){ FILE*f=fopen(argv[2],"w"); for(auto&b:M1) fprintf(f,"%ld,%.5f,%.5f,%.5f,%.5f\n",b.t,b.o,b.h,b.l,b.c); fclose(f);} 
  long start=0; for(long i=0;i<(long)M1.size();i++){ if(M1[i].t>=M1[0].t+80L*86400){start=i;break;} }
  CUR=start; if(OnInit()!=INIT_SUCCEEDED){ std::cout<<"init failed\n"; return 1; }
  for(long k=start;k<(long)M1.size()-1;k++){ engine_bar(k); CUR=k+1; OnTick(); }
  std::cout<<"OBJ created="<<OBJ_COUNT<<" rebuilds="<<OBJ_REBUILDS<<"\n"; std::cout<<"DONE deals="<<DEALS.size()<<" bars="<<(M1.size()-start)<<"\n"; return 0; }
