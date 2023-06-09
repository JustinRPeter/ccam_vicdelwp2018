      subroutine convjlm(iaero)      ! jlm convective scheme - Version v3
!     the shallow convection options here just for iterconv=1
!     has +ve fldownn depending on delta sigma; -ve uses older abs(fldown)   
!     N.B. old nevapcc option has been removed
      use aerosolldr
      use arrays_m   
      use cc_mpi, only : mydiag, myid, bounds
      use cfrac_m
      use diag_m
      use extraout_m
      use indices_m
      use kuocomb_m
      use latlong_m
      use liqwpar_m  ! ifullw
      use map_m
      use morepbl_m
      use nharrs_m, only : phi_nh
      use pbl_m  ! tss
      use prec_m
      use sigs_m
      use soil_m
      use soilsnow_m  ! for fracice
      use tkeeps, only : tke,eps,zidry
      use tracers_m  ! ngas, nllp, ntrac
      use vvel_m
      use work2_m   ! for wetfac    JLM
      implicit none
      include 'newmpar.h'
      include 'const_phys.h'
      include 'kuocom.h'   ! kbsav,ktsav,convfact,convpsav,ndavconv
      include 'parm.h'
      include 'parmdyn.h'
      include 'establ.h'

      integer itn,iq,k,k13,k23
     .       ,khalf,khalfp,kt
     .       ,ncubase,nlayers,nlayersp
     .       ,ntest,ntr,nums,nuv
     .       ,ka,kb,kc
      real convmax,delqq,delss,deltaq,delq_av,delt_av
     .    ,den1,den2,den3,detr,dprec,dqrx,entrainp,entrr,entrradd
     .    ,facuv,fldownn,fluxa,fluxb,fluxd,fluxup
     .    ,frac,fraca,fracb,gam,hbas,hbase,heatlev
     .    ,pwater,pwater0,qavg,qavgb,qentrr,qprec,qsk,rkmid
     .    ,savg,savgb,sentrr,sum,totprec,veldt
     .    ,rKa,Dva,cfls,cflscon,rhodz,qpf,pk,Apr,Bpr,Fr,rhoa,dz,Vr
     .    ,dtev,qr,qgdiff,Cev2,qr2,Cevx,alphal,blx,evapls,revq
     .    ,deluu,delvv,pb,sumb
      real delthet,tmnht1,delons,rino,dtsol

      parameter (ntest=0)      ! 1 or 2 to turn on; -1 for ldr writes
!                               -2,-3 for other detrain test      
!     parameter (iterconv=1)   ! to kuocom.h
!     parameter (fldown=.6)    ! to kuocom.h
!     parameter (detrain=.05)  ! to kuocom.h
!     parameter (alflnd=1.15)  ! e.g. 1.15  
!     parameter (alfsea=1.05)  ! e.g. 1.05  
!                                3:for RH-enhanced base
c     parameter (ncubase=2)    ! 2 from 4/06, more like 0 before  - usual
      parameter (ncubase=3)    ! 3 ensure takes local maxima
!                ncubase=0       ktmax limited in later itns
!                        1       cloud base not below that of itn 1     
!     parameter (mbase=0)      ! >0 cfrac test as %
!     parameter (methdetr=6)  
!     parameter (methprec=5)  
!     parameter (nuvconv=0)    ! usually 0, >0 or <0 to turn on momentum mixing
!     parameter (nuv=0)        ! usually 0, >0 to turn on new momentum mixing (base layers too)
      integer kcl_top          ! max level for cloud top (convjlm,radrive,vertmix)
!     nevapls:  turn off/on ls evap - through parm.h; 0 off, 5 newer UK
!     could reinstate nbase=0 & kbsav_b from .f0406
      integer ktmax(ifull),kbsav_ls(ifull),kb_sav(ifull),kt_sav(ifull)
      integer kkbb(ifull),kmin(ifull)
      integer iaero
      integer, save :: k500
      real, dimension(:), allocatable, save ::  timeconv,entrainn
      real, dimension(:,:), allocatable, save :: downex,upin,upin4
      real, dimension(:,:,:), allocatable, save :: detrarr
      integer, dimension(:), allocatable, save :: kb_saved,kt_saved
      real, dimension(ifull) :: conrev,rho,xtgsto,ttsto,qqsto,qqrain
      real, dimension(ifull) :: alfqarr,alfqarrx,omega,omgtst
      real, dimension(ifull,naero) :: fscav
      logical, dimension(ifull) :: bliqu
      real delq(ifull,kl),dels(ifull,kl),delu(ifull,kl)
      real delv(ifull,kl),dqsdt(ifull,kl),es(ifull,kl) 
      real fldow(ifull),fluxq(ifull)
      real fluxr(ifull),flux_dsk(ifull),fluxt(ifull,kl),hs(ifull,kl)  
      real phi(ifull,kl),qbase(ifull),qdown(ifull),qliqw(ifull,kl)
      real entracc(ifull,kl),entrsav(ifull,kl)
      real fluxh(ifull,kl),fluxv(ifull,kl),revc(ifull,kl)
      real qq(ifull,kl),qs(ifull,kl),qxcess(ifull)
      real qbass(ifull,kl-1)
      real rnrt(ifull),rnrtc(ifull),rnrtcn(ifull)
      real s(ifull,kl),sbase(ifull),tdown(ifull),tt(ifull,kl)
      real dsk(kl),h0(kl),q0(kl),t0(kl)  
      real qplume(ifull,kl),splume(ifull,kl)
      integer kdown(ifull)
      real entr(ifull),detrfactr(ifull),factr(ifull)
      real fluxqs,fluxt_k(kl)
      real cfraclim(ifull),convtim(ifull)
      real pblx(ifull)
      real, save:: detrainin
      integer, save:: klon2,klon23,k935
      
       kcl_top=kl-2
      if (.not.allocated(upin)) then
c        allocate(alfqarr(ifull))
c        allocate(alfqarrx(ifull))
        k500=1
        do while(sig(k500)>=0.6.and.k500<kl)
          k500=k500+1
        end do
        allocate(timeconv(ifull))
        allocate(entrainn(ifull))
        allocate(kb_saved(ifull))
        allocate(kt_saved(ifull))
        allocate(upin(kl,kl))
        allocate(upin4(kl,kl))
        allocate(downex(kl,kl))
        allocate(detrarr(kl,k500,kl))
        detrarr(:,:,:)=1.e20  ! in case someone uses other than methprec=0,4,5,6,7,8
        if(methprec==0)detrarr(:,:,:)=0.
      end if

      do k=1,kl
       dsk(k)=-dsig(k)    !   dsk = delta sigma (positive)
      enddo     ! k loop
      
      if(ktau==1)then   !---------------------------------------------------------------------------
        entrainn(:)=entrain
     
        if (alflnd<0..or.alfsea<0.) then   ! MJT suggestion
          write(6,*) "ERROR: negative alflnd and alfsea are"
          write(6,*) "not supported in convjlm"
          stop
        end if
        kb_saved(:)=kl-1
        kt_saved(:)=kl-1
        detrainin=detrain
        timeconv(:)=0.
        kb_sav(:)=kl-1
        kt_sav(:)=kl-1
        do k=1,kl
         if(sig(k)>.25)klon23=k  ! JLM
         if(sig(k)> .5)klon2=k
         if(sig(k)> .935)k935=k
        enddo
        if(mydiag)print *,'klon23,klon2,k500,k935',
     &                     klon23,klon2,k500,k935
c      precalculate detrainment arrays for various methprec
c      methprec gives the vertical distribution of the detrainment
c      methdetr gives the fraction of precip detrained (going into qxcess)
       if(methprec==4)then
       do kb=1,k500
       do kt=1,kl-1
        sumb=0.
        do k=kb+1,kt
         detrarr(k,kb,kt)=(.05+ (sig(kb)-sig(kt))*(sig(kb)-sig(k)))*
     &                      dsig(k)
         sumb=sumb+detrarr(k,kb,kt)
        enddo
        do k=kb+1,kt
         detrarr(k,kb,kt)=detrarr(k,kb,kt)/sumb
        enddo
       enddo
       enddo
       endif  ! (methprec==4)
       if(methprec==5)then  ! rather similar to old 8, but more general
       do kb=1,k500
       do kt=1,kl-1
        sumb=0.
        do k=kb+1,kt
         detrarr(k,kb,kt)=(.1+ (sig(kb)-sig(kt))*(sig(kb)-sig(k)))*
     &                      dsig(k)
         sumb=sumb+detrarr(k,kb,kt)
        enddo
        do k=kb+1,kt
         detrarr(k,kb,kt)=detrarr(k,kb,kt)/sumb
        enddo
       enddo
       enddo
       endif  ! (methprec==5)
       if(methprec==6)then
       do kb=1,k500
       do kt=1,kl-1
        sumb=0.
        do k=kb+1,kt
         detrarr(k,kb,kt)=(sig(kb)-sig(k))*dsig(k)
         sumb=sumb+detrarr(k,kb,kt)
        enddo
        do k=kb+1,kt
         detrarr(k,kb,kt)=detrarr(k,kb,kt)/sumb
        enddo
       enddo
       enddo
       endif  ! (methprec==6)
       if(methprec==7)then
       do kb=1,k500
       do kt=1,kl-1
         frac=min(1.,(sig(kb)-sig(kt))/.6)
         nlayers=kt-kb
         sum=.5*nlayers*(nlayers+1)
        do k=kb+1,kt
         detrarr(k,kb,kt)=((1.-frac)*(kt-kb)+
     &        (2.*frac-1.)*(k-kb))/
     &       (((1.-frac)*(kt-kb)**2+    
     &        (2.*frac-1.)*sum)) 
        enddo
       enddo
       enddo   
       endif  ! (methprec==7)
       if(methprec==8)then
       do kb=1,k500
       do kt=1,kl-1
         nlayers=kt-kb
         sum=.5*nlayers*(nlayers+1)
        do k=kb+1,kt
         detrarr(k,kb,kt)=(k-kb)/(sum) 
        enddo
       enddo
       enddo   
       endif  ! (methprec==8)
      if(mydiag)then
        write (6,*) "following gives kb=1 values for methprec=",methprec
        do kt=2,kl-1
         write (6,"('detrarr2-kt',17f7.3)") (detrarr(k,1,kt),k=2,kt)  ! just printed for kb=1
        enddo
       endif

c     precalculate below-base downdraft & updraft environmental contrib terms (ktau=1)
       do kb=1,kl-1   ! original proposal, kscsea=0 (small upin near sfce, large downex)
        sum=0.
        sumb=0.
        do k=1,kb
         downex(k,kb)=(sig(k)-sigmh(kb+1))*dsig(k)
         sum=sum+downex(k,kb)
         upin(k,kb)=(sig(k)-1.)*dsig(k)
         sumb=sumb+upin(k,kb)
        enddo
        do k=1,kb
         downex(k,kb)=downex(k,kb)/sum
         upin(k,kb)=upin(k,kb)/sumb
        enddo
       enddo
c     precalculate below-base downdraft & updraft environmental contrib terms
      if(kscsea==-1.or.kscsea==-2)then   ! trying to be backward compatible for upin
c      this one gives linearly increasing mass fluxes at each half level      
       do kb=1,k500
        upin4(1,kb)=(1.-sigmh(1+1))/(1.-sigmh(kb+1))
        upin(1,kb)=upin4(1,kb)
        do k=2,kb
         upin4(k,kb)=(1.-sigmh(k+1))/(1.-sigmh(kb+1))
         upin(k,kb)=upin4(k,kb)-upin4(k-1,kb)
        enddo
        if(ntest==1.and.ktau==1.and.mydiag)then
          write (6,"('upinx kb ',i3,15f7.3)") kb,(upin(k,kb),k=1,kb)
        endif
       enddo
      endif  ! kscsea==-1.or.kscsea==-2  
      if(kscsea<=-2)then   ! trying to be backward compatible for downex
c      gives relatively larger downdraft fluxes near surface      
       do kb=1,k500
        sum=0.
        do k=1,kb
         downex(k,kb)=dsig(k)
         sum=sum+downex(k,kb)
        enddo
        do k=1,kb
         downex(k,kb)=downex(k,kb)/sum
        enddo
       enddo
      endif  ! kscsea<=-2
      if(mydiag)then
        do kb=1,kl-1
         write (6,"('upin1-kb ',17f7.3)") (upin(k,kb),k=1,kb)
        if(ntest==1)write (6,"('downex',17f7.3)") (downex(k,kb),k=1,kb)
        enddo
        do kb=1,kl-1
         write (6,"('downex',17f7.3)") (downex(k,kb),k=1,kb)
        enddo
      endif
      endif    ! (ktau==1)
!---------------------------------------------------------------------------

       omega(1:ifull)=dpsldt(1:ifull,1)
      do iq=1,ifull
c     N.B. tied_con only used for mbase=-2,-17,-18,-19      
c     N.B. omgtst only used for mbase=-17,-18,-19      
c     typical tied_con=10,20 for C48, increasing for smaller ds  (i.e. 14, 28 for C96 100 km)
       if(tied_con>0.)then    
         omgtst(iq)=1.e-8*tied_con *sqrt(em(iq)*208498./ds)  
       else
c         omgtst(iq)=-1.e-8*tied_con *sqrt(sqrt(em(iq)*208498./ds))  
          omgtst(iq)=-1.e-8*tied_con *em(iq)*208498./ds  
       endif
      enddo

        do iq=1,ifull
          if(land(iq))then
            alfqarr(iq)=alflnd
          else
            alfqarr(iq)=alfsea
            if(mbase<-20)then
              dtsol=.01*sgsave(iq)/(1.+.25*(u(iq,1)**2+v(iq,1)**2))   ! solar heating   ! sea
c            tpan-tss   is .3*dtsol.  Suggest add .1 to alfqarr for dtsol=1 and mbase=-x1         
              alfqarr(iq)=alfsea-.1*(mbase+20)*dtsol ! =alfsea+(tpan-tsea) for mbase=-23
            endif
           alfqarr(iq)=fracice(iq)*alflnd+(1.-fracice(iq))*alfqarr(iq) ! MJT suggestion
          endif   ! (land(iq)) .. else ..
        enddo

        if(mbase<-20)then
         do iq=1,ifull
          if(.not.land(iq))then
              dtsol=.01*sgsave(iq)/(1.+.25*(u(iq,1)**2+v(iq,1)**2))   ! solar heating   ! sea
c            tpan-tss   is .3*dtsol.  Suggest add .1 to alfqarr for dtsol=1 and mbase=-x1         
              alfqarr(iq)=alfsea-.1*(mbase+20)*dtsol ! =alfsea+(tpan-tsea) for mbase=-23
             alfqarr(iq)=fracice(iq)*alflnd+(1.-fracice(iq))*alfqarr(iq) ! MJT suggestion
           endif   ! (.not.land(iq))
          enddo
        endif
          
c        alfqarrx reduces over land and sea for finer resolution than 200 km grid            
          if(tied_over>1.)then  ! e.g. 20 or 26
           do iq=1,ifull
            sum=ds/(em(iq)*208498.)
            alfqarrx(iq)=1.+(alfqarr(iq)-1.) *
     &      (1.+tied_over)*sum/(1.+tied_over*sum)
           enddo
          else
           do iq=1,ifull
             sum=ds/(em(iq)*208498.)
             alfqarrx(iq)=1.+(alfqarr(iq)-1.) *sqrt(sum)  ! early eqn
           enddo
          endif
        if(tied_over.ne.0.)then
          do iq=1,ifull
            alfqarrx(iq)=min(alfqarrx(iq),2.)
          enddo
        endif

        if(ktau==1.and.mydiag)write(6,"('alfqarr,alfqarrx',2f7.3)") 
     &              alfqarr(idjd),alfqarrx(idjd)
      if(mbase>0)cfraclim(:)=.0001*abs(mbase) ! mbase=1000 for 10%, 100 for 1%

c     convective first, then possibly L/S rainfall
      qliqw(:,:)=0.  
      kmin(:)=0
      conrev(1:ifull)=1000.*ps(1:ifull)/(grav*dt) ! factor to convert precip to g/m2/s
      rnrt(:)=0.       ! initialize large-scale rainfall array
      rnrtc(:)=0.      ! initialize convective  rainfall array
      ktmax(:)=kl      ! preset 1 level above current topmost-permitted ktsav
      kbsav_ls(:)=0    ! for L/S
      ktsav(:)=kl-1    ! preset value to show no deep or shallow convection
      kbsav(:)=kl-1    ! preset value to show no deep or shallow convection

      tt(1:ifull,:)=t(1:ifull,:)       
      qq(1:ifull,:)=qg(1:ifull,:)      
      phi(:,1)=bet(1)*tt(:,1)  ! moved up here May 2012
      do k=2,kl
       do iq=1,ifull
        phi(iq,k)=phi(iq,k-1)+bet(k)*tt(iq,k)
     &                      +betm(k)*tt(iq,k-1)
       enddo     ! iq loop
      enddo      ! k  loop
      if(nh.ne.0)phi(:,:)=phi(:,:)+phi_nh(:,:)  ! add non-hydrostatic component - MJT

      if(convtime>10.)then       
!       following increases convtime_eff for small grid lengths
!       e.g. for convtime=15, gives 3600. for 15km,  900. for 60km
!                         30, gives 7200. for 15km, 1800. for 60km
        convtim(:)=convtime*3.6e6*em(1:ifull)/ds
c*** removed old convtime<0 decreasing during convection option on 28/10/11
      else                                          ! original option
        convtim(:)=3600.*convtime        ! -ve defns come lfurther down
      endif  ! (convtime>10.) .. else ..
      factr(:)=dt/max(dt,convtim(:))          ! to re-scale rainfall etc, AFTER iterconv loop
c     following modification was found to be not much use
c     do iq=1,ifull
c       k=kb_sav(iq)
c       if(qq(iq,k)+qlg(iq,k)+qfg(iq,k)>qs(iq,k))factr(iq)=1.
c     enddo

      ! use boundary layer height for dry convection if EDMF is selected
      if (nvmix==6.and.nlocal==7) then
        pblx=zidry
      else
        pblx=pblh
      end if

c      following defines kb_sav (as kkbb) for use by nbase=-12     
        kkbb(:)=1
        s(1:ifull,1)=cp*tt(1:ifull,1)+phi(1:ifull,1)  ! dry static energy
       do k=2,k500   
        if(nbase==-11)then
         do iq=1,ifull
           if(cp*tt(iq,k)+phi(iq,k)<s(iq,1)+cp)kkbb(iq)=k  ! simple +1deg s check for within PBL  
         enddo    ! iq loop
        elseif(nbase==-12)then
         do iq=1,ifull
!         find tentative cloud base ! 
!            (middle of k-1 level, uppermost level below pblh)
          if(phi(iq,k-1)<pblx(iq)*grav)kkbb(iq)=k-1
         enddo    ! iq loop
       else  ! e.g. nbase=-13
         do iq=1,ifull
!         find tentative cloud base ! 
!            (uppermost layer, with approx. bottom of layer below pblh)
          if(.5*(phi(iq,k-1)+phi(iq,k))<pblx(iq)*grav)kkbb(iq)=k
         enddo    ! iq loop
        endif
c        print *,'k,phi-,phi,pblh*g,kkbb',
c    &      k,phi(idjd,k-1),phi(idjd,k),pblh(idjd)*grav,kkbb(idjd)        
       enddo     ! k loop

      if(mbase==-2)then  ! simple_max plus tpan_qs sea
       do iq=1,ifull
          k=kkbb(iq)
          alfqarr(iq)=alfqarrx(iq)*                 !  N.B. qs check done later with qbass
     &      max(qg(iq,1),qg(iq,2),qg(iq,k))/qg(iq,k)  
c        if(.not.land(iq).and.tpan(iq)-tss(iq)>.01*tied_con)then         
         if(.not.land(iq))then
           dtsol=.01*sgsave(iq)/(1.+.25*(u(iq,1)**2+v(iq,1)**2))   ! solar heating   ! sea
c         dtsol=.01*sgsave(iq)/(1.+.25*vmod(iq)**2)   ! solar heating   ! sea
c         tpan-tss   is .3*dtsol          
          if(.3*dtsol>.01*tied_con)then         
           es(iq,1)=establ(tt(iq,1))
           pk=ps(iq)*sig(1)
           qs(iq,1)=.622*es(iq,1)/max(pk-es(iq,1),1.)  
           alfqarr(iq)=alfqarrx(iq)*                 !  N.B. qs check done later with qbass
     &               max(qs(iq,1),qg(iq,2),qg(iq,k))/qg(iq,k)
          endif
         endif
       enddo 
      endif  ! mbase=-2     
      if(mbase==-17)then ! omgtst with wetfac over land, qs(k) over sea
       alfqarr(:)=alfqarrx(:)
       do iq=1,ifull
         k=kkbb(iq)
        if(omega(iq)<-omgtst(iq))then         
          if(land(iq).or.fracice(iq)>0.)then
           alfqarr(iq)=alfqarrx(iq)*
     &                 max(qg(iq,1),qg(iq,2),qg(iq,k))/qg(iq,k)
         else
c          es(iq,k)=establ(tt(iq,k))
c          pk=ps(iq)*sig(k)
c          qs(iq,k)=.622*es(iq,k)/max(pk-es(iq,k),1.)  
c          alfqarr(iq)=max(1.,qs(iq,k)/qg(iq,k))
            es(iq,1)=establ(tt(iq,1))   ! -17b
            pk=ps(iq)*sig(1)   ! -17b
            qs(iq,1)=.622*es(iq,1)/max(pk-es(iq,1),1.)     ! -17b
            alfqarr(iq)=alfqarrx(iq)*                 !  N.B. qs check done later with qbass   ! -17b
     &               max(wetfac(iq)*qs(iq,1),qg(iq,2),qg(iq,k))/qg(iq,k)   ! -17b
          endif
        endif
       enddo 
      endif  ! mbase=-17
      if(mbase==-18)then !  omgtst with max_qg over land and sea
       alfqarr(:)=alfqarrx(:)
       do iq=1,ifull
         k=kkbb(iq)
        if(omega(iq)<-omgtst(iq))then         
          alfqarr(iq)=          !  N.B. qs check done later with qbass
     &    alfqarrx(iq)*max(qg(iq,1),qg(iq,2),qg(iq,k))/qg(iq,k)
        endif
       enddo 
      endif  ! mbase=-18    
      if(mbase==-19)then ! with wetfac over land and sea 
       alfqarr(:)=alfqarrx(:)
       do iq=1,ifull
         k=kkbb(iq)
        if(omega(iq)<-omgtst(iq))then         
         es(iq,1)=establ(tt(iq,1))
         pk=ps(iq)*sig(1)
         qs(iq,1)=.622*es(iq,1)/max(pk-es(iq,1),1.)  
          alfqarr(iq)=alfqarrx(iq)*                 !  N.B. qs check done later with qbass
     &               max(wetfac(iq)*qs(iq,1),qg(iq,2),qg(iq,k))/qg(iq,k)
        endif
       enddo 
      endif  ! mbase=-19   
      if(mbase<=-20)then  ! various simple with tpan added
         alfqarr(:)=alfqarrx(:)
      endif  ! mbase<=-20     
      nuv=0
      fluxt(:,:)=0.  ! just for some compilers
   
!_____________________beginning of convective calculation loop________________
      do itn=1,abs(iterconv)
       fluxh(:,:)=0.  ! -ve into plume, +ve from downdraft
       fluxv(:,:)=0.  ! +ve for downwards subsident air
!     calculate geopotential height 
      kb_sav(:)=kl-1   ! preset value for no convection
      kt_sav(:)=kl-1   ! preset value for no convection
      rnrtcn(:)=0.     ! initialize convective rainfall array (pre convpsav)
      convpsav(:)=0.
      dels(:,:)=1.e-20
      delq(:,:)=0.
      if(nuvconv.ne.0)then 
        if(nuvconv<0)nuv=abs(nuvconv)  ! Oct 08 nuv=0 for nuvconv>0
        delu(:,:)=0.
        delv(:,:)=0.
        facuv=.1*abs(nuvconv) ! full effect for nuvconv=10
      endif

      do k=1,kl   
       do iq=1,ifull
        es(iq,k)=establ(tt(iq,k))
       enddo  ! iq loop
      enddo   ! k loop
      do k=1,kl   
       do iq=1,ifull
        pk=ps(iq)*sig(k)
c       qs(iq,k)=max(.622*es(iq,k)/(pk-es(iq,k)),1.5e-6)  
        qs(iq,k)=.622*es(iq,k)/max(pk-es(iq,k),1.)  
        dqsdt(iq,k)=qs(iq,k)*pk*hlars/(tt(iq,k)**2*max(pk-es(iq,k),1.))
        s(iq,k)=cp*tt(iq,k)+phi(iq,k)  ! dry static energy
c       calculate hs
        hs(iq,k)=s(iq,k)+hl*qs(iq,k)   ! saturated moist static energy
       enddo  ! iq loop
      enddo   ! k loop
      hs(:,:)=max(hs(:,:),s(:,:)+hl*qq(:,:))   ! added 21/7/04
      if(itn==1)then
        do k=1,kl-1  ! N.B. qbass only defined for itn=1, here:
         qbass(:,k)=min(alfqarr(:)*qq(:,k),max(qs(:,k),qq(:,k))) 
        enddo
c***    by defining qbass just for itn=1, convpsav does not converge as quickly as may be expected,
c***    as qbass may not be reduced by convpsav if already qs-limited    
c***    Also entrain may slow convergence   N.B. qbass only used in next few lines
      endif  ! (itn==1)
      qplume(:,kl)=0. ! just for diag prints  !JLM
      splume(:,kl)=0. ! just for diag prints  !JLM
      do k=1,kl-1
       qplume(:,k)=min(alfqarr(:)*qq(:,k),qbass(:,k),   ! from Jan 08
     &         max(qs(:,k),qq(:,k)))   ! to avoid qb increasing with itn
       splume(:,k)=s(:,k)  
      enddo
      if(ktau==1.and.mydiag)then
      write(6,*) 'itn,iterconv,nuv,nuvconv ',itn,iterconv,nuv,nuvconv
      write(6,*) 'ntest,methdetr,methprec,detrain,detrainx ',
     .           ntest,methdetr,methprec,detrain,detrainx
      write(6,*) 'fldown,ncubase ',fldown,ncubase
      write(6,*) 'alflnd,alfsea ',alflnd,alfsea
      write(6,*) 'cfraclim,convtim,factr ',
     &           cfraclim(idjd),convtim(idjd),factr(idjd)
      endif
      if((ntest>0.or.diag.or.nmaxpr==1).and.mydiag) then
        iq=idjd
        write (6,"('near beginning of convjlm; ktau',i5,' itn',i1)") 
     &                                         ktau,itn 
        write (6,"('rh   ',12f7.2/(5x,12f7.2))") 
     .             (100.*qq(iq,k)/qs(iq,k),k=1,kl)
        write (6,"('qs   ',12f7.3/(5x,12f7.3))") 
     .             (1000.*qs(iq,k),k=1,kl)
        write (6,"('qq   ',12f7.3/(5x,12f7.3))") 
     .             (1000.*qq(iq,k),k=1,kl)
        if(itn==1)write (6,"('qlg  ',12f7.3/(5x,12f7.3))") 
     .             (1000.*qlg(iq,k),k=1,kl)
        if(itn==1)write (6,"('qfg  ',12f7.3/(5x,12f7.3))") 
     .             (1000.*qfg(iq,k),k=1,kl)
        if(itn==1)write (6,"('qtot ',12f7.3/(5x,12f7.3))")
     &        (1000.*(qq(iq,k)+qlg(iq,k)+qfg(iq,k)),k=1,kl)
        if(itn==1)write (6,"('qtotx',12f7.3/(5x,12f7.3))")
     &        (10000.*dsk(k)*(qq(iq,k)+qlg(iq,k)+qfg(iq,k)),k=1,kl)
        pwater0=0.   ! in mm     
        do k=1,kl
         iq=idjd
         h0(k)=s(iq,k)/cp+hlcp*qq(iq,k)
         q0(k)=qq(iq,k)
         t0(k)=tt(iq,k)
         pwater0=pwater0-dsig(k)*qg(iq,k)*ps(iq)/grav
        enddo
        write (6,"('qbas  ',12f7.3/(5x,12f7.3))") 1000.*qplume(iq,:)
        write (6,"('tt    ',12f7.2/(5x,12f7.2))") tt(iq,:)
        write (6,"('s/cp  ',12f7.2/(5x,12f7.2))") s(iq,:)/cp
        write (6,"('h/cp  ',12f7.2/(5x,12f7.2))") 
     .             s(iq,:)/cp+hlcp*qq(iq,:)
        write (6,"('hb/cp',12f7.2/(5x,12f7.2))") 
     .             s(iq,:)/cp+hlcp*qplume(iq,:)
        write (6,"('hs/cp ',12f7.2/(5x,12f7.2))") hs(iq,:)/cp
        write (6,"('cfracc',12f7.3/6x,12f7.3)") cfrac(iq,:)
        write (6,"('k   ',12i7/(4x,12i7))") (k,k=1,kl)
        write (6,"('es     ',9f7.1/(7x,9f7.1))") es(iq,:)
        write (6,"('dqsdt6p',6p9f7.1/(7x,9f7.1))") dqsdt(iq,:)
        sum=0.
        do k=1,kl
         sum=sum-dsig(k)*(s(iq,k)/cp+hlcp*qq(iq,k))
        enddo
        write(6,*) 'h_sum   ',sum
      endif

      sbase(:)=0.  ! just for tracking running max, working downwards
      qbase(:)=0.  ! just for tracking running max, working downwards
!     Following procedure chooses lowest valid cloud bottom (and base)

      if(nbase==-4)then
       do k=klon2,kuocb+1,-1  ! downwards for nbase=-4 to find cloud base **k loop**
        kdown(:)=1     ! set tentatively as valid cloud bottom (not needed beyond this k loop)
!      k here is nominally level about kbase      
c      meanings of kdown for usual ncubase=3 (used for nbase=-4)
c      1  starting value
c       2 finding local max of hplume (working downwards)
c       0 local max already found
         do iq=1,ifull
!        find tentative cloud base, and bottom of below-cloud layer
         if(kdown(iq)>0)then   
!         now choose base layer to also have local max of splume+hl*qplume      
          if(splume(iq,k-1)+hl*qplume(iq,k-1)>
     &           max(hs(iq,k),sbase(iq)+hl*qbase(iq))
     &       .and.qplume(iq,k-1)>max(qs(iq,k),qq(iq,k)))then      ! newer qbas test 
             kb_sav(iq)=k-1
             qbase(iq)=qplume(iq,k-1)
             sbase(iq)=splume(iq,k-1)
             kt_sav(iq)=k
             if(ncubase==3)kdown(iq)=2
          else
            if(kdown(iq)==2)kdown(iq)=0  ! switches off remaining levels 
          endif  ! (qbas>max(qs(iq,k),qq(iq,k)).and.sbas+hl*qbas>hs(iq,k))
         endif   ! (kdown(iq)>0)
        enddo    ! iq loop             
        if(ntest>0.and.mydiag)then
         iq=idjd
         kb=kb_sav(iq)
         write(6,*) 'k,kkbb,kdown,kb_sav,kt_sav ',
     &            k,kkbb(iq),kdown(iq),kb_sav(iq),kt_sav(iq)
         write(6,*) 'phi(,k-1)/g,pblh ',phi(iq,k-1)/9.806,pblx(iq)
         write(6,*) 'qbas,qs(.,k),qq(.,k) ',
     &              qplume(iq,kb),qs(iq,k),qq(iq,k)
         write(6,*) 'splume,qplume,(splume+hl*qplume)/cp,hs(iq,k)/cp ',
     &            splume(iq,kb),qplume(iq,kb),
     &           (splume(iq,kb)+hl*qplume(iq,kb))/cp,hs(iq,k)/cp
        endif    ! (ntest>0.and.mydiag) 
       enddo     ! ******************** k loop ****************************
      else !  nbase=-12 and everything except -4
         do iq=1,ifull
!         prescribe tentative cloud base ! 
!          (e.g. middle of k-1 level, uppermost level below pblh)
           k=kkbb(iq)+1
           kb_sav(iq)=k-1
           kt_sav(iq)=k
           if(splume(iq,k-1)+hl*qplume(iq,k-1)<hs(iq,k).or.    ! just testing level above kb
     &        qplume(iq,k-1)<max(qs(iq,k),qq(iq,k)))then 
             kb_sav(iq)=kl-1
             kt_sav(iq)=kl-1
           endif  
        enddo    ! iq loop
       endif   !  nbase==-4 .. else ..

      entracc(:,:)=0.
      entrsav(:,:)=0.
      if(itn==1.and.nevapcc.ne.0)then
        if(nmaxpr==1)print *,'timeconva',timeconv(idjd)
          do iq=1,ifull
            if(timeconv(iq)>-mdelay/3600.)timeconv(iq)=0. ! -mdelay is in secs
!           will only see an effect if abs(mdelay)>dt            
          enddo
          entr(:)=sig(kb_saved(:)) -sig(kt_saved(:))
         if(entrain<1.1)then  ! handles older -ve nevapcc too
           do iq=1,ifull
              entrainn(iq)=.1*real(abs(nevapcc))*  .1/max(.1,entr(iq))  
c            for dsig=(.1,.2,.3,.4,.5,.6) 2nd term is (1, .5, .33, .25,  .2,  .17) for entrain=.1
          enddo
         elseif(nint(entrain)==2)then
           do iq=1,ifull
              if(timeconv(iq)==0.)  ! can control re-setting entrainn, with -ve mdelay
     &        entrainn(iq)=.1*real(nevapcc)*(1.-entr(iq))**2
c               for dsig (.1,.2,.3,.4,.5,.6) 2nd term is (.81, .64, .49, .36, .25, .16)
          enddo
        elseif(nint(entrain)==3)then   ! with 90 should be similar to following with 60
           do iq=1,ifull
             entrainn(iq)=.1*real(nevapcc)*(1.-entr(iq))**3
c           for dsig (.1,.2,.3,.4,.5,.6) 2nd term is (.73, .51, .34, .22 .13,  .06)
           enddo
        else ! similar to -ve nevapcc (.1/entr)  but using rational fraction
          do iq=1,ifull
            entrainn(iq)=.1*nevapcc*(4.-3.*entr(iq))/(1.+24.*entr(iq))
c             for dsig (.1,.2,.3,.4,.5,.6) 2nd term is (1.09,.59, .38, .26 .19,  .14)
         enddo
        endif  ! (nint(entrain)==2)... ...
      endif    ! (nevapcc.ne.0)
      if(mbase<=0)then
        do k=kuocb+1,kl   ! upwards to find cloud top
         do iq=1,ifull
          if((kt_sav(iq)==k-1.or.kt_sav(iq)==k).and.k<ktmax(iq))then ! ktmax allows for itn
            hbase=splume(iq,k-1)+hl*qplume(iq,k-1)
            if(hbase>hs(iq,k))then
             kt_sav(iq)=k
             entrr=-entrainn(iq)*dsig(k) ! (linear) entrained mass into plume_k
             qplume(iq,k)=qplume(iq,k-1)*
     &                     (1.+entracc(iq,k-1))+entrr*qq(iq,k)
             splume(iq,k)=splume(iq,k-1)*
     &                     (1.+entracc(iq,k-1))+entrr*s(iq,k)
             entracc(iq,k)=entracc(iq,k-1)+entrr ! running total entrained into plume
!            1+entr is net mass into plume_k (assumed well mixed), and
!            subsequently is mass out top of plume_k
             qplume(iq,k)=qplume(iq,k)/(1.+entracc(iq,k)) ! well-mixed value
             splume(iq,k)=splume(iq,k)/(1.+entracc(iq,k)) ! well-mixed value
             entrsav(iq,k)=entrr
            endif
            if(ntest>0.and.iq==idjd.and.mydiag)then
              write(6,*) 'A k,kt_sav,entrr,entracc',
     &                 k,kt_sav(iq),entrr,entracc(iq,k)
            endif
            if(ntest>0.and.entrain<0.and.iq==idjd.and.mydiag)then
              write(6,*) 'k,kb_sav,kt_sav,hbase/cp,hs/cp ',
     &                 k,kb_sav(iq),kt_sav(iq),hbase/cp,hs(iq,k)/cp
            endif
          endif   ! (kt_sav(iq)==k-1.and.k<ktmax(iq))
         enddo    ! iq loop
        enddo     ! k loop
      else              ! i.e. mbase>0 option
        do k=kuocb+1,kl   ! upwards to find cloud top
         do iq=1,ifull
          if((kt_sav(iq)==k-1.or.kt_sav(iq)==k).and.k<ktmax(iq))then ! ktmax allows for itn
            hbase=splume(iq,k-1)+hl*qplume(iq,k-1)
            if(hbase>hs(iq,k))then
             if(sig(kb_sav(iq))-sig(kt_sav(iq))>.15)then
               if(cfrac(iq,kb_sav(iq)+1)>cfraclim(iq))kt_sav(iq)=k
             else
               kt_sav(iq)=k
             endif
             entrr=-entrainn(iq)*dsig(k)
             qplume(iq,k)=qplume(iq,k-1)*
     &                     (1.+entracc(iq,k-1))+entrr*qq(iq,k)
             splume(iq,k)=splume(iq,k-1)*
     &                     (1.+entracc(iq,k-1))+entrr*s(iq,k)
             entracc(iq,k)=entracc(iq,k-1)+entrr ! running total entrained into plume
             qplume(iq,k)=qplume(iq,k)/(1.+entracc(iq,k)) ! well-mixed value
             splume(iq,k)=splume(iq,k)/(1.+entracc(iq,k)) ! well-mixed value
             entrsav(iq,k)=entrr
            endif
            if(ntest>0.and.iq==idjd.and.mydiag)then
              write(6,*) 'k,hbase/cp,hs/cp ',k,hbase/cp,hs(iq,k)/cp
              write(6,*) 'B k,kt_sav,entrr,entracc',
     &                 k,kt_sav(iq),entrr,entracc(iq,k)
            endif
          endif   ! (kt_sav(iq)==k-1.and.k<ktmax(iq))
         enddo    ! iq loop
        enddo     ! k loop
      endif
      
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

!     calculate dels and delq for all layers for unit base mass flux
!     designed to be OK if q(k)>qs(k)
      do iq=1,ifull
!      dels and delq for top layer
!      following line allows for qq>qs, to avoid drying layer
       qsk=max(qs(iq,kt_sav(iq)),qq(iq,kt_sav(iq)))  
c      entrradd=1.+entrain*(sigmh(kb_sav(iq)+1)-sigmh(kt_sav(iq)))
       entrradd=1.+entracc(iq,kt_sav(iq)-1)
       qprec=entrradd*max(0.,qplume(iq,kt_sav(iq)-1)-qsk)             
       dels(iq,kt_sav(iq))=entrradd*splume(iq,kt_sav(iq)-1) ! s flux
       if(nuv>0)then
         delu(iq,kt_sav(iq))=u(iq,kb_sav(iq))  ! no entrainment effects included for u,v
         delv(iq,kt_sav(iq))=v(iq,kb_sav(iq))
       endif  ! (nuv>0)
       delq(iq,kt_sav(iq))=entrradd*qsk  
       dels(iq,kt_sav(iq))=dels(iq,kt_sav(iq))+hl*qprec    ! precip. heating
       kdown(iq)=min(kl,kb_sav(iq)+nint(.6+.75*(kt_sav(iq)-kb_sav(iq))))
       if(nkuo>23)then 
!       following refines calc of kdown to be more accurately .75 of cloud depth       
        if(ntest>0.and.iq==idjd.and.mydiag)then
          pb=(.75*sig(kt_sav(iq))+.25*sig(kb_sav(iq))
     &            -sig(kdown(iq)))/dsig(kdown(iq))
          write(6,*) 'kdown1,kb_sav,kt_sav,dsig,pb,nint ',
     &      kdown(iq),kb_sav(iq),kt_sav(iq),dsig(kdown(iq)),pb,nint(pb)
        endif
        kdown(iq)=kdown(iq)+nint( (.75*sig(kt_sav(iq))
     &            +.25*sig(kb_sav(iq))-sig(kdown(iq)))/dsig(kdown(iq)) )
        if(ntest>0.and.iq==idjd.and.mydiag)write(6,*) 'kdown1b,sig ',
     &           kdown(iq),.75*sig(kt_sav(iq))+.25*sig(kb_sav(iq))
       endif  ! (nkuo>23)
c      qsk is value entering downdraft, qdown is value leaving downdraft
c      tdown is temperature emerging from downdraft (at cloud base)       
       qsk=min(qs(iq,kdown(iq)),qq(iq,kdown(iq))) ! N.B. min for downdraft subs
       tdown(iq)=t(iq,kb_sav(iq))+(s(iq,kdown(iq))-s(iq,kb_sav(iq))
     .      +hl*(qsk-qs(iq,kb_sav(iq))))/(cp+hl*dqsdt(iq,kb_sav(iq)))
!      don't want moistening of cloud base layer (can lead to -ve fluxes) 
c      qdown(iq)=min( qq(iq,kb_sav(iq)) , qs(iq,kb_sav(iq))+
c    .           (tdown(iq)-t(iq,kb_sav(iq)))*dqsdt(iq,kb_sav(iq)) )
       qdown(iq)= qs(iq,kb_sav(iq))+
     .           (tdown(iq)-t(iq,kb_sav(iq)))*dqsdt(iq,kb_sav(iq)) 
       dprec=qdown(iq)-qsk                      ! to be mult by fldownn
!      typically fldown=.6 or -.2        
       fldownn=max(-fldown,fldown*(sig(kb_sav(iq))-sig(kt_sav(iq))))
       totprec=qprec-fldownn*dprec 
       if(tdown(iq)>t(iq,kb_sav(iq)).or.totprec<0.)then
         fldow(iq)=0.
       else
         fldow(iq)=fldownn
       endif
       if(sig(kb_sav(iq))-sig(kt_sav(iq))<.4)fldow(iq)=0. ! suppr. downdraft
c      fldow(iq)=(.5+sign(.5,totprec))*fldownn ! suppr. downdraft for totprec<0
       rnrtcn(iq)=qprec-fldow(iq)*dprec        ! already has dsk factor
       if(ntest==1.and.iq==idjd.and.mydiag)then
         write(6,*)'qsk,qprec,totprec,dels0 ',qsk,qprec,totprec,hl*qprec 
         write(6,*) 'dprec,rnrtcn ',dprec,rnrtcn(iq)
       endif
!      add in downdraft contributions
       dels(iq,kdown(iq))=dels(iq,kdown(iq))-fldow(iq)*s(iq,kdown(iq))
       delq(iq,kdown(iq))=delq(iq,kdown(iq))-fldow(iq)*qsk
       if(nuv>0)then
         delu(iq,kdown(iq))=delu(iq,kdown(iq))-fldow(iq)*u(iq,kdown(iq))
         delv(iq,kdown(iq))=delv(iq,kdown(iq))-fldow(iq)*v(iq,kdown(iq))
       endif  ! (nuv>0)
      enddo  ! iq loop

!     calculate environment fluxes, fluxh (full levels) and fluxv (half levels)
!     N.B. fluxv usually <1 as downdraft bypasses fluxv
      do iq=1,ifull
       if(kb_sav(iq)<kl)then
         fluxh(iq,kdown(iq))=fldow(iq)
         do k=1,  kb_sav(iq)   ! +ve into plume
          fluxh(iq,k)=upin(k,kb_sav(iq))-fldow(iq)*downex(k,kb_sav(iq))
          fluxv(iq,k+1)=fluxv(iq,k)+fluxh(iq,k)
!         calculate emergent downdraft properties
          delq(iq,k)=fldow(iq)*downex(k,kb_sav(iq))*qdown(iq)
          dels(iq,k)=fldow(iq)*downex(k,kb_sav(iq))*
     .        (s(iq,kb_sav(iq))+cp*(tdown(iq)-t(iq,kb_sav(iq))))  ! correct
!         subtract contrib from cloud base layers into plume
          delq(iq,k)=delq(iq,k)-upin(k,kb_sav(iq))*qplume(iq,kb_sav(iq))
          dels(iq,k)=dels(iq,k)-upin(k,kb_sav(iq))*splume(iq,kb_sav(iq))
          if(nuv>0)then
             delu(iq,k)=-upin(k,kb_sav(iq))*u(iq,kb_sav(iq))
     &                 +fldow(iq)*downex(k,kb_sav(iq))*u(iq,kdown(iq))
             delv(iq,k)=-upin(k,kb_sav(iq))*v(iq,kb_sav(iq))
     &                 +fldow(iq)*downex(k,kb_sav(iq))*v(iq,kdown(iq))
          endif  ! (nuv>0)
         enddo   ! k loop
         do  k=kb_sav(iq)+1,kt_sav(iq)-1
          fluxh(iq,k)=entrsav(iq,k)+fluxh(iq,k) ! + adds in kdown contrib
          fluxv(iq,k+1)=fluxv(iq,k)+fluxh(iq,k)
          dels(iq,k)=dels(iq,k)-entrsav(iq,k)*s(iq,k)   ! entr into updraft
          delq(iq,k)=delq(iq,k)-entrsav(iq,k)*qq(iq,k)  ! entr into updraft
         enddo
        endif    ! (kb_sav(iq)<kl)
       enddo     ! iq loop
       if(itn==1.and.nevapcc.ne.0)then
         do iq=1,ifull
          alfqarr(iq)=min(alfqarr(iq),
     &                     qs(iq,kb_sav(iq))/qg(iq,kb_sav(iq)))
         enddo     ! iq loop       
       endif

      if((ntest>0.or.diag).and.mydiag)then
       iq=idjd
       write(6,*) 'fluxh',(fluxh(iq,k),k=1,kt_sav(iq))
       write(6,*) 'fluxv',(fluxv(iq,k),k=1,kt_sav(iq))
       entrradd=1.+entrain*(sigmh(kb_sav(iq)+1)-sigmh(kt_sav(iq)))
       write(6,*) 'ktmax,kt_sav,entracc,entrradd ',
     .          ktmax(iq),kt_sav(iq),entracc(iq,kt_sav(iq)-1),entrradd
       write(6,*) 'ktau,itn,kb_sav,kt_sav,kdown ',
     .          ktau,itn,kb_sav(iq),kt_sav(iq),kdown(iq)
       write(6,*) 'alfqarr,omega7,kb_sav',
     &             alfqarr(iq),1.e7*omega(iq),kb_sav(iq)
       write (6,"('s/cp    b',12f7.2/(5x,12f7.2))")s(iq,1:kt_sav(iq))/cp
       write (6,"('splume/cp',12f7.2/(5x,12f7.2))")
     &             splume(iq,1:kt_sav(iq))/cp
       write(6,*) 'qplume',qplume(iq,1:kt_sav(iq))*1.e3
       write (6,"('hplume/cp',12f7.2/(5x,12f7.2))") 
     &           splume(iq,1:kt_sav(iq))/cp+hlcp*qplume(iq,1:kt_sav(iq))
       write (6,"('hs/cp    ',12f7.2/(5x,12f7.2))") hs(iq,:)/cp
C      following just shows flux into kt layer, and fldown at base and top     
       write (6,"('delsa',9f8.0/(5x,9f8.0))")dels(iq,1:kt_sav(iq))
       write (6,"('delqa',3p9f8.3/(5x,9f8.3))")delq(iq,1:kt_sav(iq))
      endif

!     subsidence effects
      do k=2,kl-1
       do iq=1,ifull
         if(fluxv(iq,k)>0.)then  ! downwards
           dels(iq,k-1)=dels(iq,k-1)+fluxv(iq,k)*s(iq,k)
           delq(iq,k-1)=delq(iq,k-1)+fluxv(iq,k)*qq(iq,k)
c          if(iq==idjd)write(6,*) 'k,dels,fluxv,s',
c    &                k,dels(iq,k),fluxv(iq,k),s(iq,k)
           dels(iq,k)=dels(iq,k)-fluxv(iq,k)*s(iq,k)
           delq(iq,k)=delq(iq,k)-fluxv(iq,k)*qq(iq,k)
           if(nuv>0)then
             delu(iq,k-1)=delu(iq,k-1)+fluxv(iq,k)*u(iq,k)
             delv(iq,k-1)=delv(iq,k-1)+fluxv(iq,k)*v(iq,k)
             delu(iq,k)=delu(iq,k)-fluxv(iq,k)*u(iq,k)
             delv(iq,k)=delv(iq,k)-fluxv(iq,k)*v(iq,k)
           endif
         else
           dels(iq,k-1)=dels(iq,k-1)+fluxv(iq,k)*s(iq,k-1)
           delq(iq,k-1)=delq(iq,k-1)+fluxv(iq,k)*qq(iq,k-1)
           dels(iq,k)=dels(iq,k)-fluxv(iq,k)*s(iq,k-1)
           delq(iq,k)=delq(iq,k)-fluxv(iq,k)*qq(iq,k-1)
           if(nuv>0)then
             delu(iq,k-1)=delu(iq,k-1)+fluxv(iq,k)*u(iq,k-1)
             delv(iq,k-1)=delv(iq,k-1)+fluxv(iq,k)*v(iq,k-1)
             delu(iq,k)=delu(iq,k)-fluxv(iq,k)*u(iq,k-1)
             delv(iq,k)=delv(iq,k)-fluxv(iq,k)*v(iq,k-1)
           endif
        endif
       enddo
      enddo
      if((ntest>0.or.diag).and.mydiag)then
        iq=idjd
        write (6,"('delsb',9f8.0/(5x,9f8.0))")
     &              dels(iq,1:kt_sav(iq))
        write (6,"('delqb',3p9f8.3/(5x,9f8.3))")
     &              delq(iq,1:kt_sav(iq))
      endif

      if((ntest>0.or.diag).and.mydiag)then
        write(6,*) "before diag print of dels,delh "
        iq=idjd
        nlayersp=max(1,nint((kt_sav(iq)-kb_sav(iq)-.1)/methprec)) ! round down
        khalfp=kt_sav(iq)+1-nlayersp
        write(6,*) 'kb_sav,kt_sav',
     .           kb_sav(iq),kt_sav(iq)
        write(6,*) 'khalfp,nlayersp ',khalfp,nlayersp 
        write (6,"('delsd',9f8.0/(5x,9f8.0))")
     &              dels(iq,1:kt_sav(iq))
        write (6,"('delq*hl',9f8.0/(5x,9f8.0))")
     &              delq(iq,1:kt_sav(iq))*2.5e6
        write (6,"('delh ',9f8.0/(5x,9f8.0))")
     &             (dels(iq,k)+hl*delq(iq,k),k=1,kl)
        write (6,"('delhb',9f8.0/(5x,9f8.0))")
     &             (dels(iq,k)+alfqarr(iq)*hl*delq(iq,k),k=1,kl)
        sum=0.
        do k=kb_sav(iq),kt_sav(iq)
         sum=sum+dels(iq,k)+hl*delq(iq,k)
        enddo
        write(6,*) 'qplume,sum_delh ',qplume(iq,kb_sav(iq)),sum
      endif

!     calculate actual delq and dels
      do k=1,kl-1    
       do iq=1,ifull
          delq(iq,k)=delq(iq,k)/dsk(k)
          dels(iq,k)=dels(iq,k)/dsk(k)
       enddo     ! iq loop
      enddo      ! k loop

      if((ntest>0.or.diag).and.mydiag)then
        iq=idjd
        write(6,*) "before convpsav calc, after division by dsk"
        write (6,"('dels ',9f8.0/(5x,9f8.0))")
     &              dels(iq,1:kt_sav(iq))
        write (6,"('delq3p',3p9f8.3/(7x,9f8.3))")
     &              delq(iq,1:kt_sav(iq))
      endif

!----------------------------------------------------------------------------
!     calculate base mass flux 
      do iq=1,ifull
       if(kb_sav(iq)<kl-1)then   
!          fluxq limiter: alfqarr*new_qq(kb)>=new_qs(kb+1)
!          note satisfied for M=0, so M from following eqn gives cutoff value
!          i.e. alfqarr*[qq+M*delq]_kb=[qs+M*dqsdt*dels/cp]_kb+1
           k=kb_sav(iq)
           fluxq(iq)=max(0.,(alfqarr(iq)*qq(iq,k)-qs(iq,k+1))/ 
     .     (dqsdt(iq,k+1)*dels(iq,k+1)/cp +alfqarr(iq)*abs(delq(iq,k))))
           if(delq(iq,k)>0.)fluxq(iq)=0.    ! delq should be -ve 15/5/08
           convpsav(iq)=fluxq(iq)
       endif    ! (kb_sav(iq)<kl-1)
      enddo     ! iq loop
      
      do k=kl-1,kuocb+1,-1
       do iq=1,ifull
!       want: new_hbas>=new_hs(k), i.e. in limiting case:
!       [h+alfsarr*M*dels+alfqarr*M*hl*delq]_base 
!                                          = [hs+M*dels+M*hlcp*dels*dqsdt]_k
!       Assume alfsarr=1.
!       pre 21/7/04 occasionally got -ve fluxt, for supersaturated layers
        if(k>kb_sav(iq).and.k<=kt_sav(iq))then
c         if(dels(iq,k)*(1.+hlcp*dqsdt(iq,k))-dels(iq,kb_sav(iq))           
c    .       -alfqarr(iq)*hl*delq(iq,kb_sav(iq))<0.)
c    .       write(6,*) '-ve denom for iq,k = ',iq,k
          fluxt(iq,k)=(splume(iq,k-1)+hl*qplume(iq,k-1)-hs(iq,k))/
     .       max(1.e-9,dels(iq,k)*(1.+hlcp*dqsdt(iq,k))       ! 0804 for max
     .                -dels(iq,kb_sav(iq))                    ! to avoid zero
     .                -alfqarr(iq)*hl*delq(iq,kb_sav(iq)) )   ! with real*4
          if(fluxt(iq,k)<convpsav(iq))then   ! rhcv removed June 2012
            convpsav(iq)=fluxt(iq,k)
            kmin(iq)=k   ! level where fluxt is a minimum (diagnostic)
          endif    ! (fluxt(iq,k)<convpsav(iq))
          if(dels(iq,kb_sav(iq))+alfqarr(iq)*hl*delq(iq,kb_sav(iq))>0.)
     &             convpsav(iq)=0. 
        endif   ! (k>kb_sav(iq).and.k<kt_sav(iq))
       enddo    ! iq loop
       if((ntest>0.or.diag).and.mydiag)then
        iq=idjd
        if(k>kb_sav(iq).and.k<=kt_sav(iq))then
          den1=dels(iq,k)*(1.+hlcp*dqsdt(iq,k))
          den2=dels(iq,kb_sav(iq))
          den3=alfqarr(iq)*hl*delq(iq,kb_sav(iq))
          fluxt_k(k)=(splume(iq,k-1)+hl*qplume(iq,k-1)-hs(iq,k))/
     .                max(1.e-9,den1-den2-den3) 
         write(6,*)'k,den1,den2,den3,fluxt ',k,den1,den2,den3,fluxt_k(k)
        endif   ! (k>kb_sav(iq).and.k<kt_sav(iq))
       endif    ! ((ntest>0.or.diag).and.mydiag)
      enddo     ! k loop      

      if(ntest==2.and.mydiag)then
        convmax=0.
        do iq=1,ifull
         if(convpsav(iq)>convmax.and.kb_sav(iq)==2)then
           write(6,*) 'ktau,iq,convpsav,fluxt3,kb_sav2,kt_sav ',
     .            ktau,iq,convpsav(iq),fluxt(iq,3),kb_sav(iq),kt_sav(iq)
           idjd=iq
           convmax=convpsav(iq)
         endif
        enddo	
      endif   !  (ntest==2)
      
      if((ntest>0.or.diag).and.mydiag)then
        iq=idjd
        k=kb_sav(iq)
        if(k<kl)then
          fluxqs=(alfqarr(iq)*qq(iq,k)-qs(iq,k+1))/
     &           (dqsdt(iq,k+1)*dels(iq,k+1)/cp -alfqarr(iq)*delq(iq,k))
          write(6,*) 'alfqarr(iq)*qq(iq,k) ',alfqarr(iq)*qq(iq,k)
          write(6,*) 'alfqarr(iq)*delq(iq,k) ',alfqarr(iq)*delq(iq,k)
          write(6,*) 'qs(iq,k+1) ',qs(iq,k+1)
          write(6,*) 'dqsdt(iq,k+1)*dels(iq,k+1)/cp ',
     &             dqsdt(iq,k+1)*dels(iq,k+1)/cp
c         write(6,*) 'dqsdt(iq,k+1) ',dqsdt(iq,k+1)
c         write(6,*) 'dels(iq,k+1) ',dels(iq,k+1)
c         write(6,*) 'delq(iq,k) ',delq(iq,k)
          write(6,*) 'fluxqs ',fluxqs
        endif
        write(6,"('fluxq,convpsav',5f9.5)") fluxq(iq),convpsav(iq)
        write(6,"('delQ*dsk6p',6p9f8.3/(10x,9f8.3))")
     .    (convpsav(iq)*delq(iq,k)*dsk(k),k=1,kl)
        write(6,"('delt*dsk3p',3p9f8.3/(10x,9f8.3))")
     .   (convpsav(iq)*dels(iq,k)*dsk(k)/cp,k=1,kl)
        convmax=0.
        nums=0
        write(6,*) '    ktau   iq nums  kb kt     dsk    flt  flux',
     &         '  rhb  rht   rnrt    rnd'
        do iq=1,ifull     
         if(kt_sav(iq)-kb_sav(iq)==1)then
           nums=nums+1
           if(convpsav(iq)>convmax)then
c          if(nums<20)then
             convmax=convpsav(iq)
             write(6,"('bc  ',3i5,2i3,2x,2f7.3,f6.3,2f5.2,2f7.4)") 
     .       ktau,iq,nums,kb_sav(iq),kt_sav(iq),
     .       dsk(kb_sav(iq)),
     .       fluxt(iq,kt_sav(iq)),convpsav(iq),
     .       qq(iq,kb_sav(iq))/qs(iq,kb_sav(iq)),
     .       qq(iq,kt_sav(iq))/qs(iq,kt_sav(iq)),
     &       rnrtcn(iq),rnrtcn(iq)*convpsav(iq)*ps(iq)/grav
           endif
         endif
        enddo  ! iq loop
        convmax=0.
        nums=0
        do iq=1,ifull     
         if(kt_sav(iq)-kb_sav(iq)==2)then
           nums=nums+1
           if(convpsav(iq)>convmax)then
c          if(nums<20)then
             convmax=convpsav(iq)
             write(6,"('bcd ',3i5,2i3,2x,2f7.3,f6.3,2f5.2,2f7.4)") 
     .       ktau,iq,nums,kb_sav(iq),kt_sav(iq),
     .       dsk(kb_sav(iq)),
     .       fluxt(iq,kt_sav(iq)),convpsav(iq),
     .       qq(iq,kb_sav(iq))/qs(iq,kb_sav(iq)),
     .       qq(iq,kt_sav(iq))/qs(iq,kt_sav(iq)),
     &       rnrtcn(iq),rnrtcn(iq)*convpsav(iq)*ps(iq)/grav
           endif
         endif
        enddo  ! iq loop
        convmax=0.
        nums=0
        do iq=1,ifull     
         if(kt_sav(iq)-kb_sav(iq)==3)then
           nums=nums+1
           if(convpsav(iq)>convmax)then
c          if(nums<20)then
             convmax=convpsav(iq)
             write(6,"('bcde',3i5,2i3,2x,2f7.3,f6.3,2f5.2,2f7.4)") 
     .       ktau,iq,nums,kb_sav(iq),kt_sav(iq),
     .       dsk(kb_sav(iq)),
     .       fluxt(iq,kt_sav(iq)),convpsav(iq),
     .       qq(iq,kb_sav(iq))/qs(iq,kb_sav(iq)),
     .       qq(iq,kt_sav(iq))/qs(iq,kt_sav(iq)),
     &       rnrtcn(iq),rnrtcn(iq)*convpsav(iq)*ps(iq)/grav
           endif
         endif
        enddo  ! iq loop
      endif    ! (ntest>0.or.diag)
      
      if(nmaxpr==1.and.mydiag)then
        iq=idjd
        write(6,*) 'Total_a delq (g/kg) & delt for this itn'
        write(6,"('delQ',3p12f7.3/(4x,12f7.3))")
     &            convpsav(iq)*delq(iq,:)
        write(6,"('delT',12f7.3/(4x,12f7.3))")
     &            convpsav(iq)*dels(iq,:)/cp
        write (6,"('hb/cpo',12f7.2/(9x,12f7.2))") 
     .            (splume(iq,:)+hl*qplume(iq,:))/cp
        write (6,"('qq_n  ',12f7.3/(9x,12f7.3))") 
     &             (qq(iq,:)+convpsav(iq)*delq(iq,:))*1000.
        write (6,"('new_qbas ',12f7.3/(9x,12f7.3))") 
     &     alfqarr(iq)*(qq(iq,:)+convpsav(iq)*delq(iq,:))*1000.
c       this s and h does not yet include updated phi (or does it?)     
        write (6,"('s/cp_n',12f7.2/(9x,12f7.2))") 
     &             (s(iq,:)+convpsav(iq)*dels(iq,:))/cp 
        write (6,"('h/cp_n',12f7.2/(9x,12f7.2))") 
     &            (s(iq,:)+hl*qq(iq,:)+convpsav(iq)*
     &             (dels(iq,:)+hl*delq(iq,:)))/cp       
        write (6,"('hb/cpn',12f7.2/(9x,12f7.2))") 
     &            (splume(iq,:)+hl*qplume(iq,:)+convpsav(iq)
     &            *(dels(iq,:)+alfqarr(iq)*hl*delq(iq,:)))/cp 
        write (6,"('hs/cpn',12f7.2/(9x,12f7.2))") 
     &             (hs(iq,:)+convpsav(iq)*dels(iq,:)+
     &              (1.+hlcp*dqsdt(iq,:)))/cp  
      endif

      if(methdetr==0)qxcess(:)=detrain*rnrtcn(:)             ! e.g. .2* gives 20% detrainment
      if(sig_ct<0.)then  ! detrain for shallow clouds; only Jack uses sig_ct ~ -.8
        do iq=1,ifull
         if(sig(kt_sav(iq))>-sig_ct)then  
           qxcess(iq)=rnrtcn(iq)     ! full detrainment
         endif
        enddo  ! iq loop
      endif    !  (sig_ct<0.)    other sig_ct options removed June 2012

!     new detrain calc producing qxcess to also cope with shallow conv 
!     - usually with methprec=7 or 8 too
      if(methdetr==1)then  
        do iq=1,ifull     
         detrain=min(1.,max(.15,               ! thicknesses .1 (full) and .6 (.15)
     &           1.17-1.7*(sig(kb_sav(iq))-sig(kt_sav(iq)))))
         qxcess(iq)=detrain*rnrtcn(iq) 
        enddo
      endif   ! (methdetr==1)     
      if(methdetr==2)then  ! 09/11  NB methdetr=1 & 2 ignore detrainin  
        do iq=1,ifull     
         detrain=min(1.,max(.16,               ! thicknesses .2 (full) and .6 (.15)
     &           1.42-2.1*(sig(kb_sav(iq))-sig(kt_sav(iq)))))
         qxcess(iq)=detrain*rnrtcn(iq) 
        enddo
      endif   ! (methdetr==2)     
      if(methdetr==3)then  ! now usual (with .14 from 20/6/12)
        do iq=1,ifull     
         detrain=min( 1., detrainin+(1.-detrainin)*(   ! typical detrainin is .15
     &     (.6-min(sig(kb_sav(iq))-sig(kt_sav(iq)), .6)) /(.6-.14))**3 )
c        diff=0, .14, .2,.3, .4, .6, .7 gives detrain=1, 1, .71, .39, .22, .16, .15, .15   for .15  
         qxcess(iq)=detrain*rnrtcn(iq) 
        enddo
      endif   ! (methdetr==3)     
      if(methdetr==4)then   ! like 3 but uses .7 instead of .6 - more usual
        do iq=1,ifull     
         detrain=min( 1., detrainin+(1.-detrainin)*(   ! typical detrainin is .15
     &     (.7-min(sig(kb_sav(iq))-sig(kt_sav(iq)), .7)) /(.6-.14))**3 )
c        diff=0, .14, .2, .3, .4, .5, .6, .7 gives detrain=1, 1., 1., .71, .39, .22, .16, .15   for .15  
c        diff=0, .14, .2, .3, .4, .5, .6, .7 gives detrain=1, 1., 1., .69, .35, .17, .11, .1     for .1  
         qxcess(iq)=detrain*rnrtcn(iq) 
        enddo
      endif   ! (methdetr==4)     
      if(methdetr==5)then   ! like 4 with .7 but denom is .5
        do iq=1,ifull     
         detrain=min( 1., detrainin+(1.-detrainin)*(   ! typical detrainin is .15
     &     (.7-min(sig(kb_sav(iq))-sig(kt_sav(iq)), .7)) /.5)**3 )
c        diff=0, .14, .2, .3, .4, .5, .6, .7 gives detrain=1, 1., 1., .71, .39, .22, .16, .15   for .15 X 
c        diff=0, .14, .2, .3, .4, .5, .6, .7 gives detrain=1, 1., 1., .69, .35, .17, .11, .1     for .1  X
         qxcess(iq)=detrain*rnrtcn(iq) 
        enddo
      endif   ! (methdetr==5)     
      if(methdetr==6)then   ! like 4 with .7 but denom is .45
        do iq=1,ifull     
         detrain=min( 1., detrainin+(1.-detrainin)*(   ! typical detrainin is .15
     &     (.7-min(sig(kb_sav(iq))-sig(kt_sav(iq)), .7)) /.45)**3 )
c        diff=0, .14, .2, .3, .4, .5, .6, .7 gives detrain=1, 1., 1., .71, .39, .22, .16, .15   for .15 X 
c        diff=0, .14, .2, .3, .4, .5, .6, .7 gives detrain=1, 1., 1., .69, .35, .17, .11, .1     for .1  X
         qxcess(iq)=detrain*rnrtcn(iq) 
        enddo
      endif   ! (methdetr==6)     

      if(itn==1)then
        cape(:)=0.
        do k=2,kl-1
         do iq=1,ifull
          if(k>kb_sav(iq).and.k<=kt_sav(iq))then
            kb=kb_sav(iq)
            cape(iq)=cape(iq)-(splume(iq,kb)+hl*qplume(iq,kb)-hs(iq,k))*
     &              rdry*dsig(k)/(cp*sig(k))            
          endif
         enddo
        enddo
        if(nmaxpr==1)print *,'timeconvb',timeconv(idjd)
        do iq=1,ifull
         if(convpsav(iq)>0.)then ! for mdelay options
           timeconv(iq)=timeconv(iq)+dt/3600.
         else       ! usual
           timeconv(iq)=0.
         endif
        enddo
        if(nmaxpr==1)print *,'timeconvc,convpsav',
     &    timeconv(idjd),convpsav(idjd)
        if(convtime<0.)then
c         options to define factr so it is small for (longer-lived) shallow clouds       
         if(nint(convtime)==-1)then  ! -1.
          do iq=1,ifull    ! 20 mins for .6; 28 mins for .3; 40 mins for .15
           frac=(sig(kb_sav(iq))-sig(kt_sav(iq)))/.6  ! 28/10/11
           factr(iq)=min(1.,(dt/1200.)*sqrt(frac))       ! -1
          enddo
         endif
         if(nint(convtime)==-2)then  ! -2., a common setting
          do iq=1,ifull     ! 20 mins for .6; 27m for .45; 40m for .3; 80m for .15
           factr(iq)=min(1.,(dt/1200.)*
     &                        (sig(kb_sav(iq))-sig(kt_sav(iq)))/.6)  ! -2
          enddo
         endif
         if(nint(convtime)==-23)then  ! -23.
          do iq=1,ifull     ! 30 mins for .6
           factr(iq)=min(1.,(dt/1800.)*
     &                        (sig(kb_sav(iq))-sig(kt_sav(iq)))/.6)  ! -23
          enddo
         endif
         if(nint(convtime)==-24)then  ! -24.
          do iq=1,ifull     ! 40 mins for .6
           factr(iq)=min(1.,(dt/2400.)*
     &                        (sig(kb_sav(iq))-sig(kt_sav(iq)))/.6)  ! -24
          enddo
         endif
         if(nint(convtime)==-26)then  ! -26.,   1 hour for deep clouds
          do iq=1,ifull     ! 1 hour for .6; 81m for .45; 120m for .3; 240m for .15
           factr(iq)=min(1.,(dt/3600.)*
     &                        (sig(kb_sav(iq))-sig(kt_sav(iq)))/.6)  ! -26
          enddo
         endif
         if(nint(convtime)==-4)then  !  -4.
          do iq=1,ifull    ! 20 mins for .6; 31m for .45; 57m for .3; 160m for .15
           frac=(sig(kb_sav(iq))-sig(kt_sav(iq)))/.6  ! 28/10/11
           factr(iq)=min(1.,(dt/1200.)*frac*sqrt(frac))   ! -4
          enddo
         endif
         if(nint(convtime)==-61)then  ! -61.,   1 hour for deep clouds  poor
          do iq=1,ifull     ! 1 hour for 1.; 1.47h for .3; 5h for 0
           factr(iq)=min(1., (dt/3600.)/(1.+
     &                4.*(1.-(sig(kb_sav(iq))-sig(kt_sav(iq))))**6) )
          enddo
c         print *,'convtime,nint',convtime,nint(convtime)
c         print *,'A,B',sig(kb_sav(idjd))-sig(kt_sav(idjd)),
c    &            1.+4.*(1.-(sig(kb_sav(idjd))-sig(kt_sav(idjd))))**6         
         endif
         if(nint(convtime)==-62)then  ! -62.,   20 mins for deep clouds poor
          do iq=1,ifull     ! 20m 1.; .8h for .3; 4.33h for 0
           factr(iq)=min(1., (dt/3600.)/(.333+
     &                4.*(1.-(sig(kb_sav(iq))-sig(kt_sav(iq))))**6) ) 
          enddo
         endif
        endif  ! (convtime<0.)
      endif    ! (itn==1)
      if(nmaxpr==1.and.nevapcc.ne.0.and.mydiag)then
       write (6,
     & "('itn,kb_s,kt_s,kb,kt,delS,entr,timeconv,entrainn,factr',
     &       5i3,5f7.3)")
     &   itn,kb_saved(idjd),kt_saved(idjd),
     &   kb_sav(idjd),kt_sav(idjd), sig(kb_sav(idjd))-sig(kt_sav(idjd)),
     &   entr(idjd),timeconv(idjd),entrainn(idjd),factr(idjd) 
      endif

      if(mdelay>0)then  ! suppresses conv. unless occurred for >= mdelay secs
        do iq=1,ifull
         if(timeconv(iq)<mdelay/3600.)then
           convpsav(iq)=0.
         endif
        enddo
      endif  ! (mdelay>0)
      
      do iq=1,ifull
       if(ktsav(iq)==kl-1.and.convpsav(iq)>0.)then
         kbsav(iq)=kb_sav(iq) 
         ktsav(iq)=kt_sav(iq)  
       endif  ! (ktsav(iq)==kl-1.and.convpsav(iq)>0.)
      enddo   ! iq loop

      if(itn<iterconv.or.iterconv<0)then   ! iterconv<0 calls convjlm twice, and does convfact*
        convpsav(:)=convfact*convpsav(:) ! typically convfact=1.02  
      endif                              ! (itn<iterconv.or.iterconv<0)
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!      
      rnrtcn(:)=rnrtcn(:)-qxcess(:)

!     update qq, tt and precip
      rnrtc(:)=rnrtc(:)+convpsav(:)*rnrtcn(:)*conrev(:) ! g/m**2/s
      if(ncvcloud==0)then  ! usual
        do k=1,kl   
         do iq=1,ifull
          qq(iq,k)=qq(iq,k)+convpsav(iq)*delq(iq,k)
          tt(iq,k)=tt(iq,k)+convpsav(iq)*dels(iq,k)/cp
         enddo    ! iq loop
        enddo     ! k loop
      else
        do k=1,kl   
         do iq=1,ifull
          qq(iq,k)=qq(iq,k)+convpsav(iq)*delq(iq,k)
         enddo    ! iq loop
        enddo     ! k loop
c        fluxt here denotes delt, phi denotes del_phi
           do iq=1,ifull
            fluxt(iq,1)=convpsav(iq)*dels(iq,1)/(cp+bet(1))
            phi(iq,1)=bet(1)*fluxt(iq,1)
            tt(iq,1)=tt(iq,1)+fluxt(iq,1)
           enddo    ! iq loop
          do k=2,kl
           do iq=1,ifull
            fluxt(iq,k)=(convpsav(iq)*dels(iq,k)-phi(iq,k-1)
     &                  -betm(k)*fluxt(iq,k-1))/(cp+bet(k))
            phi(iq,k)=phi(iq,k-1)+betm(k)*fluxt(iq,k-1)
     &                +bet(k)*fluxt(iq,k)
            tt(iq,k)=tt(iq,k)+fluxt(iq,k)
           enddo    ! iq loop
        enddo     ! k loop
      endif       ! (ncvcloud==0) .. else ..
      
!!!!!!!!!!!!!!!!!!!!! "deep" detrainment using detrain !!!!!v3!!!!!!    
!     N.B. convpsav has been updated here with convfact, but without factr term  
!    includes methprec=7 & 8 but using detrarr array
c      detrfactr(:)=0.
       do k=kuocb+1,kl-1 
        do iq=1,ifull  
         if(k>kb_sav(iq).and.k<=kt_sav(iq))then
c          detrfactr(iq)=detrfactr(iq)+detrarr(k,kb_sav(iq),kt_sav(iq))   ! just a diag
           deltaq=convpsav(iq)*qxcess(iq)*
     &                   detrarr(k,kb_sav(iq),kt_sav(iq))/dsk(k)
           qliqw(iq,k)=qliqw(iq,k)+deltaq
         endif
        enddo  ! iq loop
       enddo   ! k loop
c      if(mydiag)print *,'methprec5 detrfactr,detrfactr(idjd)

      if((ntest>0.or.diag).and.mydiag)then
        iq=idjd
!       N.B. convpsav(iq) is already mult by dt jlm: mass flux is convpsav/dt
        write(6,*) "after convection: ktau,itn,kbsav,ktsav ",

     .                 ktau,itn,kb_sav(iq),kt_sav(iq)
        write (6,"('qgc ',12f7.3/(8x,12f7.3))") 
     .             (1000.*qq(iq,k),k=1,kl)
        write (6,"('ttc ',12f7.2/(8x,12f7.2))") 
     .             (tt(iq,k),k=1,kl)
        write(6,*) 'rnrtc,qxcess ',rnrtc(iq),qxcess(iq)
        write(6,*) 'rnrtcn,convpsav ',rnrtcn(iq),convpsav(iq)
        write(6,*) 'ktsav,qplume,qs_ktsav,qq_ktsav ',kt_sav(iq),
     .         qplume(iq,kb_sav(iq)),qs(iq,kt_sav(iq)),qq(iq,kt_sav(iq)) 
        iq=idjd
        delq_av=0.
        delt_av=0.
        heatlev=0.
        do k=1,kl
         delq_av=delq_av+dsk(k)*convpsav(iq)*delq(iq,k)
         delt_av=delt_av+dsk(k)*convpsav(iq)*dels(iq,k)/cp
         heatlev=heatlev+sig(k)*dsk(k)*convpsav(iq)*dels(iq,k)/cp
        enddo
        write(6,*) 'delq_av,delt_exp,rnd_exp ',
     .         delq_av,-delq_av*hl/cp,-delq_av*conrev(iq)
        if(delt_av.ne.0.)write(6,*) 
     &        'ktau,itn,kbsav,ktsav,delt_av,heatlev',
     .        ktau,itn,kb_sav(iq),kt_sav(iq),delt_av,heatlev/delt_av
      endif   ! (ntest>0.or.diag)
      
!     update u & v using actual delu and delv (i.e. divided by dsk)
7     if(nuvconv.ne.0.or.nuv>0)then
        if(ntest>0.and.mydiag)then
          write(6,*) 'u,v before convection'
          write (6,"('u  ',12f7.2/(3x,12f7.2))") u(idjd,:)
          write (6,"('v  ',12f7.2/(3x,12f7.2))") v(idjd,:)
        endif
        do k=1,kl-2   
         do iq=1,ifull
          u(iq,k)=u(iq,k)+facuv*factr(iq)*convpsav(iq)*delu(iq,k)/dsk(k)
          v(iq,k)=v(iq,k)+facuv*factr(iq)*convpsav(iq)*delv(iq,k)/dsk(k)
         enddo  ! iq loop
        enddo   ! k loop
        if(ntest>0.and.mydiag)then
          write(6,*) 'u,v after convection'
          write (6,"('u  ',12f7.2/(3x,12f7.2))") u(idjd,:)
          write (6,"('v  ',12f7.2/(3x,12f7.2))") v(idjd,:)
        endif
      endif     ! (nuvconv.ne.0)

!     section for convective transport of trace gases (jlm 22/2/01)
      if(ngas>0)then
        do ntr=1,ngas
         do k=1,kl-2
          do iq=1,ifull
           s(iq,k)=tr(iq,k,ntr)
          enddo    ! iq loop
         enddo     ! k loop
         do iq=1,ifull
          if(kt_sav(iq)<kl-1)then
            kb=kb_sav(iq)
            kt=kt_sav(iq)
            veldt=factr(iq)*convpsav(iq)*(1.-fldow(iq)) ! simple treatment
            fluxup=veldt*s(iq,kb)
!           remove gas from cloud base layer
            tr(iq,kb,ntr)=tr(iq,kb,ntr)-fluxup/dsk(kb)
!           put flux of gas into top convective layer
            tr(iq,kt,ntr)=tr(iq,kt,ntr)+fluxup/dsk(kt)
            do k=kb+1,kt
             tr(iq,k,ntr)=tr(iq,k,ntr)-s(iq,k)*veldt/dsk(k)
             tr(iq,k-1,ntr)=tr(iq,k-1,ntr)+s(iq,k)*veldt/dsk(k-1)
            enddo
          endif
         enddo   ! iq loop
        enddo    ! ntr loop    
      endif      ! (ngas>0)

      ! Convective transport of TKE and eps - MJT
      if (nvmix==6) then
        s(:,1:kl-2)=tke(1:ifull,1:kl-2)
        do iq=1,ifull
         if(kt_sav(iq)<kl-1)then
           kb=kb_sav(iq)
           kt=kt_sav(iq)
           veldt=factr(iq)*convpsav(iq)*(1.-fldow(iq)) ! simple treatment
           fluxup=veldt*s(iq,kb)
!          remove tke from cloud base layer
           tke(iq,kb)=tke(iq,kb)-fluxup/dsk(kb)
!          put flux of tke into top convective layer
           tke(iq,kt)=tke(iq,kt)+fluxup/dsk(kt)
           do k=kb+1,kt
            tke(iq,k)=tke(iq,k)-s(iq,k)*veldt/dsk(k)
            tke(iq,k-1)=tke(iq,k-1)+s(iq,k)*veldt/dsk(k-1)
           enddo
         endif
        enddo   ! iq loop
        s(:,1:kl-2)=eps(1:ifull,1:kl-2)
        do iq=1,ifull
         if(kt_sav(iq)<kl-1)then
           kb=kb_sav(iq)
           kt=kt_sav(iq)
           veldt=factr(iq)*convpsav(iq)*(1.-fldow(iq)) ! simple treatment
           fluxup=veldt*s(iq,kb)
!          remove eps from cloud base layer
           eps(iq,kb)=eps(iq,kb)-fluxup/dsk(kb)
!          put flux of eps into top convective layer
           eps(iq,kt)=eps(iq,kt)+fluxup/dsk(kt)
           do k=kb+1,kt
            eps(iq,k)=eps(iq,k)-s(iq,k)*veldt/dsk(k)
            eps(iq,k-1)=eps(iq,k-1)+s(iq,k)*veldt/dsk(k-1)
           enddo
         endif
        enddo   ! iq loop        
      end if

      ! Convective transport of aerosols - MJT
      if (abs(iaero)==2) then
        ! This is a simple approximation where all rain is attributed to
        ! kt_save.  However, rain is actually attributed to kt_save (qprec)
        ! kdown (fldow(iq)*qsk) and kb_sav (-fldow(iq)*qdown(iq)).
        do iq=1,ifull
          kt=min(kt_sav(iq),kl-1)
          ttsto(iq)=tt(iq,kt)
          qqsto(iq)=qq(iq,kt)
          rho(iq)=ps(iq)*sig(kt)/(rdry*ttsto(iq))
          bliqu(iq)=ttsto(iq)>=253.16
          qqrain(iq)=qqsto(iq)+convpsav(iq)*rnrtcn(iq)
          xtgsto(iq)=xtg(iq,kt,3)
        end do
        call convscav(fscav,qqsto,qqrain,bliqu,ttsto,xtgsto,rho)
        do ntr=1,naero
          s(:,1:kl-2)=xtg(1:ifull,1:kl-2,ntr)
          do iq=1,ifull
           if(kt_sav(iq)<kl-1)then
             kb=kb_sav(iq)
             kt=kt_sav(iq)
             veldt=factr(iq)*convpsav(iq)*(1.-fldow(iq)) ! simple treatment
             fluxup=veldt*s(iq,kb)
!            remove aerosol from lower layer
             xtg(iq,kb,ntr)=xtg(iq,kb,ntr)-fluxup/dsk(kb)
!            put flux of aerosol into upper layer
             xtg(iq,kt,ntr)=xtg(iq,kt,ntr)+fluxup* 
     &                       (1.-fscav(iq,ntr))/dsk(kt)
             do k=kb+1,kt
              xtg(iq,k,ntr)=xtg(iq,k,ntr)-s(iq,k)*veldt/dsk(k)
              xtg(iq,k-1,ntr)=xtg(iq,k-1,ntr)+s(iq,k)*veldt/dsk(k-1)
             enddo
           endif
          enddo   ! iq loop
        end do
      end if
      
      if((ntest>0.or.diag).and.mydiag)then
        iq=idjd
        write (6,"('uuc ',12f6.1/(4x,12f6.1))") (u(iq,k),k=1,kl)
        write (6,"('vvc ',12f6.1/(4x,12f6.1))") (v(iq,k),k=1,kl)
      endif

      if(nmaxpr==1.and.mydiag)then
       iq=idjd
       write (6,"('ktau,itn,kb_sav,kmin,kdown,kt_sav,cfrac+,entrainn,'
     &  'rnrtcn,convpsav3,cape ',
     &   i5,i3,']',4i3,f5.2,f6.2,f8.5,3pf7.3,1pf8.1)")
     &   ktau,itn,kb_sav(iq),kmin(iq),kdown(iq),kt_sav(iq),
     &   cfrac(iq,kb_sav(iq)+1),entrainn(iq),rnrtcn(iq),
     &   convpsav(iq),cape(iq)
       write (6,"('pblh,fldow,tdown,qdown,fluxq3',
     &             f8.2,f5.2,f7.2,3p2f8.3,1pf8.2)")
     &     pblx(iq),fldow(iq),tdown(iq),qdown(iq),fluxq(iq)
       write(6,"('ktau,kkbb,wetfac,alfqarr,omega8,-omgtst8',
     &             i5,i3,2f6.3,8pf9.3,f7.3)") ktau,kkbb(idjd),
     &      wetfac(idjd),alfqarr(idjd),omega(idjd),-omgtst(idjd)
       write(6,"('fluxt3',3p14f10.3)") fluxt(iq,kb_sav(iq)+1:kt_sav(iq))
      endif
      if(ntest>0.and.nmaxpr==1.and.mydiag)then
        write(6,*) 'at end of itn loop'
        iq=idjd
        phi(iq,1)=bet(1)*tt(iq,1)  ! N.B. these recalcs interfere with reprod if just nmaxpr=1
        do k=2,kl
         phi(iq,k)=phi(iq,k-1)+bet(k)*tt(iq,k)+betm(k)*tt(iq,k-1)
        enddo      ! k  loop
        do k=1,kl   
         s(iq,k)=cp*tt(iq,k)+phi(iq,k)  ! dry static energy
        enddo   ! k loop
        write (6,"('s/cp_y',12f7.2/(5x,12f7.2))") (s(iq,k)/cp,k=1,kl)
        write (6,"('h/cp_y',12f7.2/(5x,12f7.2))") 
     .             (s(iq,k)/cp+hlcp*qq(iq,k),k=1,kl)
        sum=0.
        do k=1,kl
         sum=sum-dsig(k)*(s(iq,k)/cp+hlcp*qq(iq,k))
        enddo
        write(6,*) 'h_sumnew',sum
        sum=0.
        do k=1,kl
         sum=sum-dsig(k)*(dels(iq,k)/cp+hlcp*delq(iq,k))
        enddo
        write(6,*) 'non-scaled delh_sum   ',sum
      endif  ! (ntest>0.and.nmaxpr==1.and.mydiag)
      
      if(itn==1)then
        kb_saved(:)=kb_sav(:)
        kt_saved(:)=kt_sav(:)
      else
        do iq=1,ifull
         if(kt_sav(iq)<kl-1)then
c          itns 2 & 3 only update saved values if convection occurred         
            kb_saved(iq)=kb_sav(iq)
            kt_saved(iq)=kt_sav(iq)
         endif
        enddo
      endif

      enddo     ! itn=1,abs(iterconv)
!-------------------------------------------------------------------      

      if(nmaxpr==1.and.mydiag)then
        write(6,*) 'convtime,factr,kb_sav,kt_sav',convtime,factr(idjd)
     &          ,kb_sav(idjd),kt_sav(idjd)
      endif
      rnrtc(:)=factr(:)*rnrtc(:)
      do k=1,kl
      qq(1:ifull,k)=qg(1:ifull,k)+factr(:)*(qq(1:ifull,k)-qg(1:ifull,k))
      qliqw(1:ifull,k)=factr(:)*qliqw(1:ifull,k)      
      tt(1:ifull,k)= t(1:ifull,k)+factr(:)*(tt(1:ifull,k)- t(1:ifull,k))
      enddo

!     update qq, tt for evap of qliqw (qliqw arose from moistening)
      if(ldr.ne.0)then
!       Leon's stuff here, e.g.
        do k=1,kl
          if(rhmois==0.)then  ! Nov 2012
!           this is older simpler option, allowing ldr scheme to assign qfg without time complications          
            qlg(1:ifull,k)=qlg(1:ifull,k)+qliqw(1:ifull,k)
          else
           do iq=1,ifullw
            if(tt(iq,k)<253.16)then   ! i.e. -20C
              qfg(iq,k)=qfg(iq,k)+qliqw(iq,k)
              tt(iq,k)=tt(iq,k)+3.35e5*qliqw(iq,k)/cp   ! fusion heating
            else
              qlg(iq,k)=qlg(iq,k)+qliqw(iq,k)
            endif
           enddo
          endif !  (rhmois==0.)
         enddo  ! k loop
      else      ! for ldr=0
        qq(1:ifull,:)=qq(1:ifull,:)+qliqw(1:ifull,:)         
        tt(1:ifull,:)=tt(1:ifull,:)-hl*qliqw(1:ifull,:)/cp   ! evaporate it
        qliqw(1:ifull,:)=0.   ! just for final diags
      endif  ! (ldr.ne.0)
!______________________end of convective calculations_____________________
     
      if((ntest>0.or.diag).and.mydiag)then
        iq=idjd
        write(6,*) "after convection"
        write (6,"('qge ',12f7.3/(8x,12f7.3))")(1000.*qq(iq,k),k=1,kl)
        write (6,"('qlg  ',12f7.3/(5x,12f7.3))")(1000.*qlg(iq,k),k=1,kl)
        write (6,"('qfg  ',12f7.3/(5x,12f7.3))")(1000.*qfg(iq,k),k=1,kl)
        write (6,"('qtot ',12f7.3/(5x,12f7.3))")
     &        (1000.*(qq(iq,k)+qlg(iq,k)+qfg(iq,k)),k=1,kl)
        write (6,"('qtotx',12f7.3/(5x,12f7.3))")
     &        (10000.*dsk(k)*(qq(iq,k)+qlg(iq,k)+qfg(iq,k)),k=1,kl)
        write (6,"('tte ',12f6.1/(8x,12f6.1))")(tt(iq,k),k=1,kl)
        write(6,*) 'rnrtc ',rnrtc(iq)
        delt_av=0.
        heatlev=0.
!       following calc of integ. column heatlev really needs iterconv=1  
         do k=kl-2,1,-1
          delt_av=delt_av-dsk(k)*revc(iq,k)*hlcp
          heatlev=heatlev-sig(k)*dsk(k)*revc(iq,k)*hlcp
          write (6,"('k, rh, delt_av, heatlev',i5,f7.2,2f10.2)")
     .                k,100.*qq(iq,k)/qs(iq,k),delt_av,heatlev
         enddo
         if(delt_av.ne.0.)write(6,*) 'ktau,delt_av-net,heatlev_net ',
     .                             ktau,delt_av,heatlev/delt_av
      endif
      if(ldr.ne.0)go to 8

!_______________beginning of large-scale calculations (for ldr=0: rare setting)________
!     check for grid-scale rainfall 
      do k=1,kl   
       do iq=1,ifull
        es(iq,k)=establ(tt(iq,k))
       enddo  ! iq loop
      enddo   ! k loop
      do k=kl,1,-1    ! top down to end up with proper kbsav_ls
       do iq=1,ifull
        pk=ps(iq)*sig(k)
        qs(iq,k)=.622*es(iq,k)/max(pk-es(iq,k),1.)  
        if(qq(iq,k)>rhsat*qs(iq,k))then
          kbsav_ls(iq)=k
          gam=hlcp*qs(iq,k)*pk*hlars/(tt(iq,k)**2*max(pk-es(iq,k),1.)) 
          dqrx=(qq(iq,k)-rhsat*qs(iq,k))/(1.+rhsat*gam)
          tt(iq,k)=tt(iq,k)+hlcp*dqrx
          qq(iq,k)=qq(iq,k)-dqrx
          rnrt(iq)=rnrt(iq)+dqrx*dsk(k)
        endif   ! (qq(iq,k)>rhsat*qs(iq,k))
       enddo    ! iq loop
      enddo     ! k loop

!!!!!!!!!!!!!!!!  now do evaporation of L/S precip (for ldr=0: rare setting) !!!!!!!!!!!!!!!!!!
!     conrev(iq)=1000.*ps(iq)/(grav*dt)     
      rnrt(:)=rnrt(:)*conrev(:)                 
!     here the rainfall rate rnrt has been converted to g/m**2/sec
      fluxr(:)=rnrt(:)*1.e-3*dt ! kg/m2      

      if((ntest>0.or.diag).and.mydiag)then
        iq=idjd
        write(6,*) 'after large scale rain: kbsav_ls,rnrt ',
     .                                   kbsav_ls(iq),rnrt(iq)
        write (6,"('qg ',12f7.3/(8x,12f7.3))") 
     .             (1000.*qq(iq,k),k=1,kl)
        write (6,"('tt ',12f7.2/(8x,12f7.2))") 
     .             (tt(iq,k),k=1,kl)
      endif

      if(nevapls>.0)then ! even newer UKMO (just for ldr=0)
        rKa=2.4e-2
        Dva=2.21
        cfls=1. ! cld frac7 large scale
        cflscon=4560.*cfls**.3125
        do k=klon23,1,-1  ! JLM
         do iq=1,ifull
          if(k<kbsav_ls(iq))then
            rhodz=ps(iq)*dsk(k)/grav
            qpf=fluxr(iq)/rhodz     ! Mix ratio of rain which falls into layer
            pk=ps(iq)*sig(k)
c           es(iq,k)=qs(iq,k)*pk/.622
            Apr=hl*hl/(rKa*tt(iq,k)*(rvap*tt(iq,k))-1.)
            Bpr=rvap*tt(iq,k)*pk/(Dva*es(iq,k))
            Fr=fluxr(iq)/(cfls*dt)
            rhoa=pk/(rdry*tt(iq,k))
            dz=pk/(rhoa*grav)
            Vr=max(.01 , 11.3*Fr**(1./9.)/sqrt(rhoa)) ! Actual fall speed
            dtev=dz/Vr
            qr=fluxr(iq)/(dt*rhoa*Vr)
            qgdiff=qs(iq,k)-qq(iq,k)
            Cev2=cflscon*qgdiff/(qs(iq,k)*(Apr+Bpr))  ! Ignore rhoa**0.12
            qr2=max(0. , qr**.3125 - .3125*Cev2*dtev)**3.2
!           Cev=(qr-qr2)/(dtev*qgdiff)
            Cevx=(qr-qr2)/dtev  ! i.e. Cev*qgdiff
            alphal=hl*qs(iq,k)/(ars*tt(iq,k)**2)
!           bl=1.+Cev*dt*(1.+hlcp*alphal)
            blx=qgdiff+Cevx*dt*(1.+hlcp*alphal)  ! i.e. bl*qgdiff
!           evapls= cfls*dt*qgdiff*Cev/bl        ! UKMO
            evapls= cfls*dt*Cevx*qgdiff/blx      ! UKMO
            evapls=max(0. , min(evapls,qpf))
            qpf=qpf-evapls
c           if(evapls>0.)write(6,*) 'iq,k,evapls ',iq,k,evapls
            fluxr(iq)=fluxr(iq)+rhodz*qpf
            revq=evapls
            revq=min(revq , rnrt(iq)/(conrev(iq)*dsk(k)))
!           max needed for roundoff
            rnrt(iq)=max(1.e-10 , rnrt(iq)-revq*dsk(k)*conrev(iq))
            tt(iq,k)=tt(iq,k)-revq*hlcp
            qq(iq,k)=qq(iq,k)+revq
          endif   ! (k<kbsav_ls(iq))
         enddo    ! iq loop
        enddo     ! k loop
      endif       ! (nevapls>0)
!__________________end of large-scale calculations (for ldr=0: very rare setting)________

8     if(nmaxpr==1.and.mydiag)then
        iq=idjd
        write(6,*) 'Total delq (g/kg) & delt after all itns'
        write(6,"('delQ_t',3p12f7.3/(6x,12f7.3))")
     .   (qq(iq,k)+qliqw(iq,k)-qg(iq,k),k=1,kl)
        write(6,"('delT_t',12f7.3/(6x,12f7.3))")
     .   (tt(iq,k)-t(iq,k),k=1,kl)
      endif
      qg(1:ifull,:)=qq(1:ifull,:)                   
      condc(1:ifull)=.001*dt*rnrtc(1:ifull)      ! convective precip for this timestep
      precc(1:ifull)=precc(1:ifull)+condc(1:ifull)        
      condx(1:ifull)=condc(1:ifull)+.001*dt*rnrt(1:ifull) ! total precip for this timestep
      conds(1:ifull)=0.
      precip(1:ifull)=precip(1:ifull)+condx(1:ifull)
      t(1:ifull,:)=tt(1:ifull,:)             

      if(ntest>0.or.diag.or.(ktau<=2.and.nmaxpr==1))then
       if(mydiag)then
        iq=idjd
        write(6,*) 'at end of convjlm: kdown,rnrt,rnrtc',
     &                                     kdown(iq),rnrt(iq),rnrtc(iq)
        phi(iq,1)=bet(1)*tt(iq,1)
        do k=2,kl
         phi(iq,k)=phi(iq,k-1)+bet(k)*tt(iq,k)+betm(k)*tt(iq,k-1)
        enddo      ! k  loop
        do k=1,kl   
         es(iq,k)=establ(tt(iq,k))
         pk=ps(iq)*sig(k)
         qs(iq,k)=.622*es(iq,k)/max(pk-es(iq,k),1.)  
         s(iq,k)=cp*tt(iq,k)+phi(iq,k)  ! dry static energy
         hs(iq,k)=s(iq,k)+hl*qs(iq,k)   ! saturated moist static energy
        enddo   ! k loop
        write (6,"('rhx   ',12f7.2/(5x,12f7.2))") 
     .             (100.*qq(iq,k)/qs(iq,k),k=1,kl)
        write (6,"('qsx   ',12f7.3/(5x,12f7.3))") 
     .             (1000.*qs(iq,k),k=1,kl)
        write (6,"('qqx   ',12f7.3/(5x,12f7.3))") 
     .             (1000.*qq(iq,k),k=1,kl)
        write (6,"('ttx   ',12f7.2/(5x,12f7.2))") 
     .             (tt(iq,k),k=1,kl)
        write (6,"('s/cpx ',12f7.2/(5x,12f7.2))") (s(iq,k)/cp,k=1,kl)
        write (6,"('h/cpx ',12f7.2/(5x,12f7.2))") 
     .             (s(iq,k)/cp+hlcp*qq(iq,k),k=1,kl)
        write (6,"('hb/cpx',12f7.2/(5x,12f7.2))") 
     .             (s(iq,k)/cp+hlcp*qplume(iq,k),k=1,kl)
        write (6,"('hs/cpx',12f7.2/(5x,12f7.2))") 
     .             (hs(iq,k)/cp,k=1,kl)
        write (6,"('k  ',12i7/(3x,12i7))") (k,k=1,kl)
        write(6,*) 'following are h,q,t changes during timestep'
        write (6,"('delh ',12f7.3/(5x,12f7.3))") 
     .             (s(iq,k)/cp+hlcp*qq(iq,k)-h0(k),k=1,kl)
        write (6,"('delq ',3p12f7.3/(5x,12f7.3))") 
     .             (qq(iq,k)-q0(k),k=1,kl)
        write (6,"('delt ',12f7.3/(5x,12f7.3))") 
     .             (tt(iq,k)-t0(k),k=1,kl)
        write(6,"('fluxq,convpsav',5f8.5)") ! printed 1st 2 steps
     .           fluxq(iq),convpsav(iq)
        write(6,"('fluxt',9f8.5/(5x,9f8.5))")
     .            (fluxt(iq,k),k=1,kt_sav(iq))
        pwater=0.   ! in mm     
        do k=1,kl
         pwater=pwater-dsig(k)*qg(iq,k)*ps(iq)/grav
        enddo
        write(6,*) 'pwater0,pwater+condx,pwater ',
     .           pwater0,pwater+condx(iq),pwater
        write(6,*) 'D condx ',condx(iq)
        write(6,*) 'precc,precip ',
     .           precc(iq),precip(iq)
       endif   ! (mydiag) needed here for maxmin
       call maxmin(rnrtc,'rc',ktau,1.,1)
      endif
      
      if(ntest==-1.and.nproc==1.and.ktau==10)then
        do k=1,kl
         do iq=il*il+1,2*il*il
          den1=qfg(iq,k)+qlg(iq,k)
          if(land(iq).and.den1>0.)then
            write(26,'(4f9.4,2i6)')
     &       t(iq,k),qfg(iq,k)/den1,1000.*qfg(iq,k),1000.*qlg(iq,k),iq,k
          endif
         enddo
        enddo     
      endif  ! (ntest==-1.and.nproc==1)  
      return
      end
