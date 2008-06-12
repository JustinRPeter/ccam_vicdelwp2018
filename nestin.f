      subroutine nestin               
      use cc_mpi, only : myid, mydiag
      use diag_m
      include 'newmpar.h'
!     ik,jk,kk are array dimensions read in infile - not for globpea
!     int2d code - not used for globpea
      include 'aalat.h'
      include 'arrays.h'
      include 'const_phys.h'
      include 'dates.h'    ! mtimer
      include 'dava.h'
      include 'davb.h'     ! psls,qgg,tt,uu,vv
      include 'indices.h'
      include 'latlong.h'
      include 'map.h'
      include 'parm.h'     ! qgmin
      include 'pbl.h'      ! tss
      include 'sigs.h'
      include 'soil.h'     ! sicedep fracice
      include 'soilsnow.h' ! tgg
      include 'stime.h'    ! kdate_s,ktime_s  sought values for data read
      common/nest/ta(ifull,kl),ua(ifull,kl),va(ifull,kl),psla(ifull),
     .            tb(ifull,kl),ub(ifull,kl),vb(ifull,kl),pslb(ifull),
     .            qa(ifull,kl),qb(ifull,kl),tssa(ifull),tssb(ifull),
     .            sicedepb(ifull),fraciceb(ifull)
      common/schmidtx/rlong0x,rlat0x,schmidtx ! infile, newin, nestin, indata
      real sigin
      integer ik,jk,kk
      common/sigin/ik,jk,kk,sigin(kl)  ! for vertint, infile
      real zsb(ifull)
      integer num,mtimea,mtimeb
      data num/0/,mtimea/0/,mtimeb/-1/
      save num,mtimea,mtimeb
!     mtimer, mtimeb are in minutes
      if(ktau<100.and.myid==0)then
        print *,'in nestin ktau,mtimer,mtimea,mtimeb ',
     &                     ktau,mtimer,mtimea,mtimeb
        print *,'with kdate_s,ktime_s >= ',kdate_s,ktime_s
      end if
      if(mtimeb==-1)then
        if ( myid==0 )
     &  print *,'set nesting fields to those already read in via indata'
        do iq=1,ifull
         pslb(iq)=psl(iq)
         tssb(iq)=tss(iq)
         sicedepb(iq)=sicedep(iq)  ! maybe not needed
         fraciceb(iq)=fracice(iq)
        enddo
        tb(1:ifull,:)=t(1:ifull,:)
        qb(1:ifull,:)=qg(1:ifull,:)
        ub(1:ifull,:)=u(1:ifull,:)
        vb(1:ifull,:)=v(1:ifull,:)
        mtimeb=-2
        return
      endif       ! (mtimeb==-1)

      if(mtimer<=mtimeb)go to 6  ! allows for dt<1 minute
      if(mtimeb==-2)mtimeb=mtimer  
!     transfer mtimeb fields to mtimea and update sice variables
      mtimea=mtimeb
      psla(:)=pslb(:)
      tssa(:)=tssb(:)
      ta(1:ifull,:)=tb(1:ifull,:)
      qa(1:ifull,:)=qb(1:ifull,:)
      ua(1:ifull,:)=ub(1:ifull,:)
      va(1:ifull,:)=vb(1:ifull,:)
!     following sice updating code moved from sflux Jan '06      
!     check whether present ice points should change to/from sice points
      do iq=1,ifull
       if(fraciceb(iq)>0.)then
!        N.B. if already a sice point, keep present tice (in tgg3)
         if(fracice(iq)==0.)then
           tgg(iq,3)=min(271.2,tssb(iq),tb(iq,1)+.04*6.5) ! for 40 m lev1
         endif  ! (fracice(iq)==0.)
!        set averaged tss (tgg1 setting already done)
         tss(iq)=tgg(iq,3)*fraciceb(iq)+tssb(iq)*(1.-fraciceb(iq))
       endif  ! (fraciceb(iq)==0.)
      enddo	! iq loop
      sicedep(:)=sicedepb(:)  ! from Jan 06
      fracice(:)=fraciceb(:)
!     because of new zs etc, ensure that sice is only over sea
      do iq=1,ifull
       if(fracice(iq)<.02)fracice(iq)=0.
       if(land(iq))then
         sicedep(iq)=0.
         fracice(iq)=0.
       else
         if(fracice(iq)>0..and.sicedep(iq)==0.)then
!          assign to 2. in NH and 1. in SH (according to spo)
!          do this in indata, amipdata and nestin because of onthefly
           if(rlatt(iq)>0.)then
             sicedep(iq)=2.
           else
             sicedep(iq)=1.
           endif ! (rlatt(iq)>0.)
         elseif(fracice(iq)==0..and.sicedep(iq)>0.)then  ! e.g. from Mk3  
           fracice(iq)=1.
         endif  ! (fracice(iq)>0..and.sicedep(iq)==0.) .. elseif ..
       endif    ! (land(iq))
      enddo     ! iq loop

!     read tb etc  - for globpea, straight into tb etc
      if(io_in==1)then
        call infil(1,kdate_r,ktime_r,timeg_b,ds_r, 
     .              pslb,zsb,tssb,sicedepb,fraciceb,tb,ub,vb,qb)
      endif   ! (io_in==1)

      if(io_in==-1)then
         call onthefl(1,kdate_r,ktime_r,
     &                 pslb,zsb,tssb,sicedepb,fraciceb,tb,ub,vb,qb) 
      endif   ! (io_in==1)
      tssb(:) = abs(tssb(:))  ! moved here Mar '03
      if (mydiag) then
        write (6,"('zsb# nestin  ',9f7.1)") diagvals(zsb)
        write (6,"('tssb# nestin ',9f7.1)") diagvals(tssb) 
      end if
   
      if(abs(rlong0  -rlong0x)>.01.or.
     &   abs(rlat0    -rlat0x)>.01.or.
     &   abs(schmidt-schmidtx)>.01)stop "grid mismatch in infile"

!     kdhour=(ktime_r-ktime)/100     ! integer hour diff
      kdhour=ktime_r/100-ktime/100   ! integer hour diff from Oct '05
      kdmin=(ktime_r-100*(ktime_r/100))-(ktime-100*(ktime/100))
      if ( myid == 0 ) then
        print *,'nesting file has: kdate_r,ktime_r,kdhour,kdmin ',
     &                             kdate_r,ktime_r,kdhour,kdmin
      end if
      mtimeb=60*24*(iabsdate(kdate_r,kdate)-iabsdate(kdate,kdate))
     .               +60*kdhour+kdmin
      if ( myid == 0 ) then
        print *,'kdate_r,iabsdate ',kdate_r,iabsdate(kdate_r,kdate)
        print *,'giving mtimeb = ',mtimeb
!     print additional information
        print *,' kdate ',kdate,' ktime ',ktime
        print *,'timeg,mtimer,mtimea,mtimeb: ',
     &           timeg,mtimer,mtimea,mtimeb
        print *,'ds,ds_r ',ds,ds_r
      end if

!     ensure qb big enough, but not too big in top levels (from Sept '04)
      qb(1:ifull,1:kk)=max(qb(1:ifull,1:kk),qgmin)
      do k=kk-2,kk
       qb(1:ifull,k)=min(qb(1:ifull,k),10.*qgmin)
      enddo

      if(mod(ktau,nmaxpr)==0.or.ktau==2.or.diag)then
!       following is useful if troublesome data is read in
        if ( myid == 0 ) then
          print *,'following max/min values printed from nestin'
        end if
        call maxmin(ub,'ub',ktau,1.,kk)
        call maxmin(vb,'vb',ktau,1.,kk)
        call maxmin(tb,'tb',ktau,1.,kk)
        call maxmin(qb,'qb',ktau,1.e3,kk)
        if ( myid == 0 ) then
          print *,'following are really psl not ps'
        end if
        call maxmin(pslb,'ps',ktau,100.,1)
      endif

!     if(kk<kl)then
      if(abs(sig(2)-sigin(2))>.0001)then   ! 11/03
!       this section allows for different number of vertical levels
!       presently assume sigin (up to kk) levels are set up as per nsig=6
!       option in eigenv, though original csiro9 levels are sufficiently
!       close for these interpolation purposes.
        if(ktau==1.and.mydiag)then
          print*,'calling vertint with kk,sigin ',kk,sigin(1:kk)
        endif
        if(diag.and.mydiag)then
          print *,'kk,sigin ',kk,(sigin(k),k=1,kk)
          print *,'tb before vertint ',(tb(idjd,k),k=1,kk)
        endif
        call vertint(tb,1)  ! transforms tb from kk to kl
        if(diag.and.mydiag)then
          print *,'tb after vertint ',(tb(idjd,k),k=1,kk)
          print *,'qb before vertint ',(qb(idjd,k),k=1,kk)
        endif
        call vertint(qb,2)
        if(diag.and.mydiag)print *,'qb after vertint ',qb(idjd,1:kk)
        call vertint(ub,3)
        call vertint(vb,4)
      endif  ! (abs(sig(2)-sigin(2))>.0001)

!     N.B. tssb (sea) only altered for newtop=2 (done here now)
      if(newtop==2)then
!       reduce sea tss to mslp      e.g. for QCCA in NCEP GCM
        do iq=1,ifull
         if(tssb(iq)<0.)tssb(iq)=
     .                       tssb(iq)-zsb(iq)*stdlapse/grav  ! N.B. -
        enddo
      endif  ! (newtop==2)

      if(newtop>=1)then
!       in these cases redefine pslb, tb and (effectively) zsb using zs
!       this keeps fine-mesh land mask & zs
!       presently simplest to do whole pslb, tb (& qb) arrays
        if(nmaxpr==1.and.mydiag)then
          print *,'zs (idjd) :',zs(idjd)
          print *,'zsb (idjd) :',zsb(idjd)
          write (6,"('100*psl.wesn ',2p5f8.3)") psl(idjd),psl(iw(idjd)),
     &              psl(ie(idjd)),psl(is(idjd)),psl(in(idjd))
          write (6,"('ps.wesn ',-2p5f9.3)") ps(idjd),
     &           ps(iw(idjd)),ps(ie(idjd)),ps(is(idjd)),ps(in(idjd))
          print *,'pslb in(idjd) :',pslb(idjd)
          print *,'now call retopo from nestin'
        endif
        call retopo(pslb,zsb,zs,tb,qb)
        if(nmaxpr==1.and.mydiag)then
          write (6,"('100*pslb.wesn ',2p5f8.3)") pslb(idjd),
     &       pslb(iw(idjd)),pslb(ie(idjd)),pslb(is(idjd)),pslb(in(idjd))
          print *,'pslb out(idjd) :',pslb(idjd)
          print *,'after pslb print; num= ',num
        endif
      endif   !  newtop>=1

      if(num==0)then
        num=1
        call printa('zs  ',zs        ,ktau,0  ,ia,ib,ja,jb,0.,.01)
        call printa('zsb ',zsb       ,ktau,0  ,ia,ib,ja,jb,0.,.01)
        call printa('psl ',psl       ,ktau,0  ,ia,ib,ja,jb,0.,1.e2)
        call printa('pslb',pslb      ,ktau,0  ,ia,ib,ja,jb,0.,1.e2)
        call printa('t   ',t,ktau,nlv,ia,ib,ja,jb,200.,1.)
        call printa('tb  ',tb,ktau,nlv,ia,ib,ja,jb,200.,1.)
        call printa('u   ',u,ktau,nlv,ia,ib,ja,jb,0.,1.)
        call printa('ub  ',ub,ktau,nlv,ia,ib,ja,jb,0.,1.)
        call printa('v   ',v,ktau,nlv,ia,ib,ja,jb,0.,1.)
        call printa('vb  ',vb,ktau,nlv,ia,ib,ja,jb,0.,1.)
        call printa('davt',davt,0,0,ia,ib,ja,jb,0.,10.)
        return
      endif   !  num==0

!     now use tt, uu, vv arrays for time interpolated values
6     timerm=ktau*dt/60.   ! real value in minutes (in case dt < 60 seconds)
      cona=(mtimeb-timerm)/real(mtimeb-mtimea)
      conb=(timerm-mtimea)/real(mtimeb-mtimea)
      psls(:)=cona*psla(:)+conb*pslb(:)
      tt (:,:)=cona*ta(:,:)+conb*tb(:,:)
      qgg(:,:)=cona*qa(:,:)+conb*qb(:,:)
      uu (:,:)=cona*ua(:,:)+conb*ub(:,:)
      vv (:,:)=cona*va(:,:)+conb*vb(:,:)

!     calculate time interpolated tss 
      if(namip.ne.0)return     ! namip SSTs/sea-ice take precedence
      do iq=1,ifull
       if(.not.land(iq))then
         tss(iq)=cona*tssa(iq)+conb*tssb(iq)
         tgg(iq,1)=tss(iq)
       endif  ! (.not.land(iq))
      enddo   ! iq loop 
      return
      end

      subroutine nestinb  ! called for mbd>0 - spectral filter method
!     this is x-y-z version      
      use cc_mpi, only : myid, mydiag
      use diag_m
      implicit none
      integer, parameter :: ntest=0 
      include 'newmpar.h'
      include 'aalat.h'
      include 'arrays.h'
      include 'const_phys.h'
      include 'darcdf.h' ! for ncid
      include 'netcdf.inc'
      include 'mpif.h'
      include 'dates.h'    ! mtimer
      include 'indices.h'
      include 'latlong.h'
      include 'liqwpar.h'  ! ifullw,qfg,qlg
      include 'parm.h'     ! qgmin
      include 'pbl.h'      ! tss
      include 'sigs.h'
      include 'soil.h'     ! sicedep fracice
      include 'soilsnow.h' ! tgg
      include 'stime.h'    ! kdate_s,ktime_s  sought values for data read
      common/nest/ta(ifull,kl),ua(ifull,kl),va(ifull,kl),psla(ifull),
     .            tb(ifull,kl),ub(ifull,kl),vb(ifull,kl),pslb(ifull),
     .            qa(ifull,kl),qb(ifull,kl),tssa(ifull),tssb(ifull),
     .            sicedepb(ifull),fraciceb(ifull)
      common/schmidtx/rlong0x,rlat0x,schmidtx ! infile, newin, nestin, indata
      real sigin
      integer ik,jk,kk
      common/sigin/ik,jk,kk,sigin(kl)  ! for vertint, infile
      integer mtimeb,kdate_r,ktime_r
      integer ::  iabsdate,iq,k,kdhour,kdmin
      real :: ds_r,rlong0x,rlat0x
      real :: schmidtx,timeg_b
      real :: psla,pslb,qa,qb,ta,tb,tssa,tssb,ua,ub,va,vb
      real :: fraciceb,sicedepb
      real, dimension(ifull) ::  zsb
      data mtimeb/-1/
      save mtimeb
      
      if(mtimer<mtimeb)return
 
!     mtimer, mtimeb are in minutes
      if(ktau<100.and.myid==0)then
        print *,'in nestinb ktau,mtimer,mtimeb,io_in ',
     &                      ktau,mtimer,mtimeb,io_in
        print *,'with kdate_s,ktime_s >= ',kdate_s,ktime_s
      end if

      if(mtimer==mtimeb)then 
        call getspecdata(pslb,ub,vb,tb,qb)
        if ( myid == 0 ) then
          print *,'following after getspecdata are really psl not ps'
        end if
        call maxmin(pslb,'pB',ktau,100.,1)
!       calculate time interpolated tss 
        if(namip.ne.0.or.ntest.ne.0)return  ! namip SSTs/sea-ice take precedence
        do iq=1,ifull
         if(.not.land(iq))then
           tss(iq)=tssb(iq)
           tgg(iq,1)=tss(iq)
         endif  ! (.not.land(iq))
        enddo   ! iq loop 
        return
      endif   ! (mtimer==mtimeb)

!     following (till end of subr) reads in next bunch of data in readiness
!     read tb etc  - for globpea, straight into tb etc
       if(io_in==1)then
         call infil(1,kdate_r,ktime_r,timeg_b,ds_r, 
     .               pslb,zsb,tssb,sicedepb,fraciceb,tb,ub,vb,qb)
       endif   ! (io_in==1)

       if(io_in==-1)then
          call onthefl(1,kdate_r,ktime_r,
     &                  pslb,zsb,tssb,sicedepb,fraciceb,tb,ub,vb,qb) 
       endif   ! (io_in==1)
       tssb(:) = abs(tssb(:))  ! moved here Mar '03
       if (mydiag) then
         write (6,"('zsb# nestinb  ',9f7.1)") diagvals(zsb)
         write (6,"('tssb# nestinb ',9f7.1)") diagvals(tssb) 
       end if
   
       if(abs(rlong0  -rlong0x)>.01.or.
     &    abs(rlat0    -rlat0x)>.01.or.
     &    abs(schmidt-schmidtx)>.01)stop "grid mismatch in infile"

       kdhour=ktime_r/100-ktime/100   ! integer hour diff from Oct '05
       kdmin=(ktime_r-100*(ktime_r/100))-(ktime-100*(ktime/100))
       if ( myid == 0 ) then
         print *,'nestinb file has: kdate_r,ktime_r,kdhour,kdmin ',
     &                              kdate_r,ktime_r,kdhour,kdmin
       end if
       mtimeb=60*24*(iabsdate(kdate_r,kdate)-iabsdate(kdate,kdate))
     .                +60*kdhour+kdmin
       if ( myid == 0 ) then
         print *,'kdate_r,iabsdate ',kdate_r,iabsdate(kdate_r,kdate)
         print *,'giving mtimeb = ',mtimeb
!        print additional information
         print *,' kdate ',kdate,' ktime ',ktime
         print *,'timeg,mtimer,mtimeb: ',
     &            timeg,mtimer,mtimeb ! MJT CHANGE - delete mtimea
         print *,'ds,ds_r ',ds,ds_r
       end if

!      ensure qb big enough, but not too big in top levels (from Sept '04)
       qb(1:ifull,1:kk)=max(qb(1:ifull,1:kk),qgmin)
       do k=kk-2,kk
        qb(1:ifull,k)=min(qb(1:ifull,k),10.*qgmin)
       enddo

       if(mod(ktau,nmaxpr)==0.or.ktau==2.or.diag)then
!        following is useful if troublesome data is read in
         if ( myid == 0 ) then
           print *,'following max/min values printed from nestin'
         end if
         call maxmin(ub,'ub',ktau,1.,kk)
         call maxmin(vb,'vb',ktau,1.,kk)
         call maxmin(tb,'tb',ktau,1.,kk)
         call maxmin(qb,'qb',ktau,1.e3,kk)
       endif
       if ( myid == 0 ) then
         print *,'following in nestinb after read pslb are psl not ps'
       end if
       call maxmin(pslb,'pB',ktau,100.,1)

!      if(kk<kl)then
       if(abs(sig(2)-sigin(2))>.0001)then   ! 11/03
!        this section allows for different number of vertical levels
!        presently assume sigin (up to kk) levels are set up as per nsig=6
!        option in eigenv, though original csiro9 levels are sufficiently
!        close for these interpolation purposes.
         if(ktau==1.and.mydiag)then
           print*,'calling vertint with kk,sigin ',kk,sigin(1:kk)
         endif
         if(diag.and.mydiag)then
           print *,'kk,sigin ',kk,(sigin(k),k=1,kk)
           print *,'tb before vertint ',(tb(idjd,k),k=1,kk)
         endif
         call vertint(tb,1)  ! transforms tb from kk to kl
         if(diag.and.mydiag)then
           print *,'tb after vertint ',(tb(idjd,k),k=1,kk)
           print *,'qb before vertint ',(qb(idjd,k),k=1,kk)
         endif
         call vertint(qb,2)
         if(diag.and.mydiag)print *,'qb after vertint ',qb(idjd,1:kk)
         call vertint(ub,3)
         call vertint(vb,4)
       endif  ! (abs(sig(2)-sigin(2))>.0001)

!      N.B. tssb (sea) only altered for newtop=2 (done here now)
       if(newtop==2)then
!        reduce sea tss to mslp      e.g. for QCCA in NCEP GCM
         do iq=1,ifull
          if(tssb(iq)<0.)tssb(iq)=
     .                        tssb(iq)-zsb(iq)*stdlapse/grav  ! N.B. -
         enddo
       endif  ! (newtop==2)

       if(newtop>=1)then
!        in these cases redefine pslb, tb and (effectively) zsb using zs
!        this keeps fine-mesh land mask & zs
!        presently simplest to do whole pslb, tb (& qb) arrays
         if(mydiag)then
           print *,'zs (idjd) :',zs(idjd)
           print *,'zsb (idjd) :',zsb(idjd)
           write (6,"('100*psl.wesn ',2p5f8.3)") psl(idjd),
     &           psl(iw(idjd)),psl(ie(idjd)),psl(is(idjd)),psl(in(idjd))
           write (6,"('ps.wesn ',-2p5f9.3)") ps(idjd),
     &           ps(iw(idjd)),ps(ie(idjd)),ps(is(idjd)),ps(in(idjd))
           print *,'pslb in(idjd) :',pslb(idjd)
           print *,'call retopo from nestin; psl# prints refer to pslb'
         endif
         call retopo(pslb,zsb,zs,tb,qb)
         if(mydiag)then
           write (6,"('100*pslb.wesn ',2p5f8.3)") pslb(idjd),
     &       pslb(iw(idjd)),pslb(ie(idjd)),pslb(is(idjd)),pslb(in(idjd))
         endif
       endif   !  newtop>=1
     
      return
      end

      ! This subroutine gathers data for the MPI version of spectral downscaling
      subroutine getspecdata(pslb,ub,vb,tb,qb)

      use cc_mpi
      
      implicit none

      include 'newmpar.h'    ! ifull_g,kl
      include 'arrays.h'     ! u,v,t,qg,psl
      include 'const_phys.h'
      include 'parm.h'       ! mbd,schmidt,nud_uv,nud_p,nud_t,nud_q,kbotdav
      include 'xyzinfo.h'
      include 'vecsuv.h'
      include 'vecsuv_g.h'   ! ax_g,bx_g,ay_g,by_g,az_g,bz_g
      
      real, dimension(ifull), intent(in) :: pslb
      real, dimension(ifull,kl), intent(in) :: ub,vb,tb,qb
      real, dimension(ifull) :: delta,costh,sinth
      real, dimension(ifull_g) :: x_g,xx_g,pslc
      real, dimension(ifull_g,kbotdav:kl) :: uc,vc,wc,tc,qc
      real den,polenx,poleny,polenz,zonx,zony,zonz
      integer iq,k

      if(nud_uv==3)then
        polenx=-cos(rlat0*pi/180.)
        poleny=0.
        polenz=sin(rlat0*pi/180.)
        do iq=1,ifull
         zonx=            -polenz*y(iq)
         zony=polenz*x(iq)-polenx*z(iq)
         zonz=polenx*y(iq)
         den=sqrt( max(zonx**2 + zony**2 + zonz**2,1.e-7) ) 
         costh(iq)= (zonx*ax(iq)+zony*ay(iq)+zonz*az(iq))/den
         sinth(iq)=-(zonx*bx(iq)+zony*by(iq)+zonz*bz(iq))/den
        enddo
      endif

      if (myid == 0) then     
        print *,"Gather data for spectral downscale"
        if(nud_p>0)call ccmpi_gather(pslb(:)-psl(1:ifull), pslc(:))
        if(nud_uv==3)then
          do k=kbotdav,kl
            delta(:)=costh(:)*(ub(1:ifull,k)-u(1:ifull,k))  ! uzon
     &              -sinth(:)*(vb(1:ifull,k)-v(1:ifull,k))
            call ccmpi_gather(delta(:), wc(:,k))
          end do
        elseif(nud_uv.ne.0)then
          do k=kbotdav,kl
            call ccmpi_gather(ub(1:ifull,k)-u(1:ifull,k), x_g(:))
            call ccmpi_gather(vb(1:ifull,k)-v(1:ifull,k), xx_g(:))
            uc(:,k)=ax_g(:)*x_g(:)+bx_g(:)*xx_g(:)
            vc(:,k)=ay_g(:)*x_g(:)+by_g(:)*xx_g(:)
            wc(:,k)=az_g(:)*x_g(:)+bz_g(:)*xx_g(:)
          end do
        endif
        if(nud_t>0)then
          do k=kbotdav,kl
            call ccmpi_gather(tb(1:ifull,k)-t(1:ifull,k), tc(:,k))
          end do
        end if
        if(nud_q>0)then
          do k=kbotdav,kl
            call ccmpi_gather(qb(1:ifull,k)-qg(1:ifull,k), qc(:,k))
          end do
        end if
      else
        if(nud_p>0)call ccmpi_gather(pslb(:)-psl(1:ifull))
        if(nud_uv==3)then
          do k=kbotdav,kl
            delta(:)=costh(:)*(ub(1:ifull,k)-u(1:ifull,k))  ! uzon
     &              -sinth(:)*(vb(1:ifull,k)-v(1:ifull,k))
          end do	
        elseif(nud_uv.ne.0)then
          do k=kbotdav,kl
            call ccmpi_gather(ub(1:ifull,k)-u(1:ifull,k))
            call ccmpi_gather(vb(1:ifull,k)-v(1:ifull,k))
          end do
        endif
        if(nud_t>0)then
          do k=kbotdav,kl
            call ccmpi_gather(tb(1:ifull,k)-t(1:ifull,k))
          end do
        endif
        if(nud_q>0)then
          do k=kbotdav,kl
            call ccmpi_gather(qb(1:ifull,k)-qg(1:ifull,k))
          end do
        endif
      end if
 
      !-----------------------------------------------------------------------
      if(nud_uv<0)then 
        if (myid == 0) then
          print *,"Fast spectral downscale"
          call fastspec((.1*real(mbd)/(pi*schmidt))**2
     &       ,pslc,uc,vc,wc,tc,qc) ! e.g. mbd=40
        end if
      elseif(nud_uv==9)then 
        if (myid == 0) print *,"Two dimensional spectral downscale"
        call slowspecmpi(myid,.1*real(mbd)/(pi*schmidt)
     &                ,pslc,uc,vc,wc,tc,qc) ! MJT CHANGE spec
      else          !  usual choice e.g. for nud_uv=1 or 2
        if (myid == 0) print *,"Separable 1D downscale (MPI)"
        call fourspecmpi(myid,.1*real(mbd)/(pi*schmidt)
     &                ,pslc,uc,vc,wc,tc,qc)
      endif  ! (nud_uv<0) .. else ..
        !-----------------------------------------------------------------------

      if (myid == 0) then
        print *,"Distribute data from spectral downscale"
        if (nud_p.gt.0) then
          call ccmpi_distribute(delta(:), pslc(:))
          psl(1:ifull)=psl(1:ifull)+delta(:)
        end if
        if(nud_uv==3)then
          do k=kbotdav,kl        
            call ccmpi_distribute(delta(:), wc(:,k))
            u(1:ifull,k)=u(1:ifull,k)+costh(:)*delta(:)
            v(1:ifull,k)=v(1:ifull,k)-sinth(:)*delta(:)
	  end do
        elseif(nud_uv.ne.0) then
          do k=kbotdav,kl        
            x_g(:)=ax_g(:)*uc(:,k)+ay_g(:)*vc(:,k)+az_g(:)*wc(:,k)
            call ccmpi_distribute(delta(:), x_g(:))
            u(1:ifull,k)=u(1:ifull,k)+delta(:)
            xx_g(:)=bx_g(:)*uc(:,k)+by_g(:)*vc(:,k)+bz_g(:)*wc(:,k)
            call ccmpi_distribute(delta(:), xx_g(:))
            v(1:ifull,k)=v(1:ifull,k)+delta(:)
          end do
        end if
        if (nud_t.gt.0) then
          do k=kbotdav,kl
            call ccmpi_distribute(delta(:), tc(:,k))
            t(1:ifull,k)=t(1:ifull,k)+delta(:)
          end do
        end if
        if (nud_q.gt.0) then
          do k=kbotdav,kl
            call ccmpi_distribute(delta(:), qc(:,k))
            qg(1:ifull,k)=max(qg(1:ifull,k)+delta(:),qgmin)
          end do
        end if
      else
        if (nud_p.gt.0) then
          call ccmpi_distribute(delta(:))
          psl(1:ifull)=psl(1:ifull)+delta(:)
        end if
        if(nud_uv==3)then
          do k=kbotdav,kl
            call ccmpi_distribute(delta(:))
            u(1:ifull,k)=u(1:ifull,k)+costh(:)*delta(:)
            v(1:ifull,k)=v(1:ifull,k)-sinth(:)*delta(:)
          end do
        elseif (nud_uv.ne.0) then
          do k=kbotdav,kl
            call ccmpi_distribute(delta(:))
            u(1:ifull,k)=u(1:ifull,k)+delta(:)
            call ccmpi_distribute(delta(:))
            v(1:ifull,k)=v(1:ifull,k)+delta(:)
          end do
        end if
        if (nud_t.gt.0) then
          do k=kbotdav,kl
            call ccmpi_distribute(delta(:))
            t(1:ifull,k)=t(1:ifull,k)+delta(:)
          end do
        end if
        if (nud_q.gt.0) then
          do k=kbotdav,kl
            call ccmpi_distribute(delta(:))
            qg(1:ifull,k)=max(qg(1:ifull,k)+delta(:),qgmin)
          end do
        end if
      end if
      
      ps(1:ifull)=1.e5*exp(psl(1:ifull)) ! Do not think this is needed, but kept it anyway - MJT
            
      return
      end subroutine getspecdata


      ! Fast spectral downscaling (JLM version)
      subroutine fastspec(cutoff2,psla,ua,va,wa,ta,qa)
      
      implicit none
      
      include 'newmpar.h'    ! ifull_g,kl
      include 'const_phys.h' ! rearth,pi,tpi
      include 'map_g.h'      ! em_g
      include 'indices_g.h'  ! in_g,ie_g,is_g,iw_g
      include 'parm.h'       ! ds,kbotdav
      include 'xyzinfo_g.h'    ! x_g,y_g,z_g

      integer, parameter :: ntest=0 
      integer i,j,k,n,n1,iq,iq1,num
      real, intent(in) :: cutoff2
      real, dimension(ifull_g), intent(inout) :: psla
      real, dimension(ifull_g,kbotdav:kl), intent(inout) :: ua,va,wa
      real, dimension(ifull_g,kbotdav:kl), intent(inout) :: ta,qa
      real, dimension(ifull_g) :: psls,sumwt
      real, dimension(ifull_g) :: psls2
      real, dimension(ifull_g), save :: xx,yy,zz
      real, dimension(ifull_g,kbotdav:kl) :: uu,vv,ww,tt,qgg
      real, dimension(ifull_g,kbotdav:kl) :: uu2,vv2,ww2,tt2,qgg2
      real emmin,dist,dist1,wt,wt1,xxmax,yymax,zzmax
      data num/1/
      save num
      
      ! myid must = 0 to get here.  So there is no need to check.
      
      if (num==1) then
      num=2
!       set up geometry for filtering through panel 1
!       x pass on panels 1, 2, 4, 5
!       y pass on panels 0, 1, 3, 4
!       z pass on panels 0, 2, 3, 5
        xx=0.
        yy=0.
        zz=0.
        do iq=1+il_g*il_g,3*il_g*il_g
          xx(iq)=xx(iw_g(iq))+sqrt((x_g(iq)-x_g(iw_g(iq)))**2+
     &           (y_g(iq)-y_g(iw_g(iq)))**2+(z_g(iq)-z_g(iw_g(iq)))**2)
        enddo
         do iq=1+4*il_g*il_g,6*il_g*il_g
          xx(iq)=xx(is_g(iq))+sqrt((x_g(iq)-x_g(is_g(iq)))**2+
     &           (y_g(iq)-y_g(is_g(iq)))**2+(z_g(iq)-z_g(is_g(iq)))**2)
        enddo
        do iq=1,2*il_g*il_g
          yy(iq)=yy(is_g(iq))+sqrt((x_g(iq)-x_g(is_g(iq)))**2+
     &           (y_g(iq)-y_g(is_g(iq)))**2+(z_g(iq)-z_g(is_g(iq)))**2)
        enddo
        do iq=1+3*il_g*il_g,5*il_g*il_g
          yy(iq)=yy(iw_g(iq))+sqrt((x_g(iq)-x_g(iw_g(iq)))**2+
     &           (y_g(iq)-y_g(iw_g(iq)))**2+(z_g(iq)-z_g(iw_g(iq)))**2)
        enddo
        if(mbd>0)then
         do iq=1,il_g*il_g
          zz(iq)=zz(iw_g(iq))+sqrt((x_g(iq)-x_g(iw_g(iq)))**2+
     &           (y_g(iq)-y_g(iw_g(iq)))**2+(z_g(iq)-z_g(iw_g(iq)))**2)
         enddo
         do iq=1+2*il_g*il_g,4*il_g*il_g
          zz(iq)=zz(is_g(iq))+sqrt((x_g(iq)-x_g(is_g(iq)))**2+
     &           (y_g(iq)-y_g(is_g(iq)))**2+(z_g(iq)-z_g(is_g(iq)))**2)
         enddo
         do iq=1+5*il_g*il_g,6*il_g*il_g
          zz(iq)=zz(iw_g(iq))+sqrt((x_g(iq)-x_g(iw_g(iq)))**2+
     &           (y_g(iq)-y_g(iw_g(iq)))**2+(z_g(iq)-z_g(iw_g(iq)))**2)
         enddo
        endif  ! (mbd>0)
        if(ntest>0)then
          do iq=1,144
           print *,'iq,xx,yy,zz ',iq,xx(iq),yy(iq),zz(iq)
          enddo
          do iq=il_g*il_g,il_g*il_g+il_g
           print *,'iq,xx,yy,zz ',iq,xx(iq),yy(iq),zz(iq)
          enddo
         do iq=4*il_g*il_g-il_g,4*il_g*il_g
           print *,'iq,xx,yy,zz ',iq,xx(iq),yy(iq),zz(iq)
          enddo
         do iq=5*il_g*il_g-il_g,5*il_g*il_g
           print *,'iq,xx,yy,zz ',iq,xx(iq),yy(iq),zz(iq)
          enddo
          print *,'xx mid:'   
          do i=1,48
           print *,'i xx',i,xx(il_g*il_g*1.5+i)
          enddo
          do i=1,48
           print *,'i xx',i+il_g,xx(il_g*il_g*2.5+i)
          enddo
          do i=1,48
           print *,'i xx',i+2*il_g,xx(il_g*il_g*4-il_g/2+i*il_g)
          enddo
          do i=1,48
           print *,'i xx',i+3*il_g,xx(il_g*il_g*5-il_g/2+i*il_g)
          enddo
          print *,'yy mid:'   
          do j=1,96
           print *,'j yy',j,yy(-il_g/2+j*il_g)
          enddo
          do j=1,48
           print *,'j yy',j+2*il_g,yy(il_g*il_g*3.5+j)
          enddo
          do j=1,48
           print *,'j yy',j+3*il_g,yy(il_g*il_g*4.5+j)
          enddo
!         wrap-around values defined by xx(il_g,5*il_g+j),j=1,il_g; yy(i,5*il_g),i=1,il_g
          print *,'wrap-round values'
          do j=1,il_g
           print *,'j,xx ',j,xx(6*il_g*il_g+1-j)       ! xx(il_g+1-j,il_g,5)
          enddo
          do i=1,il_g
           print *,'i,yy ',i,yy(5*il_g*il_g+il_g-il_g*i)   ! yy(il_g,il_g+1-i,4)
          enddo
          do j=1,il_g
           print *,'j,zz ',j,zz(5*il_g*il_g+il_g*j)      ! zz(il_g,j,5)
          enddo
        endif  ! ntest>0
      endif    !  num==1

      qgg(1:ifull_g,kbotdav:kl)=0.
      tt(1:ifull_g,kbotdav:kl)=0.
      uu(1:ifull_g,kbotdav:kl)=0.
      vv(1:ifull_g,kbotdav:kl)=0.
      ww(1:ifull_g,kbotdav:kl)=0.
      psls(1:ifull_g)=0.
      qgg2(1:ifull_g,kbotdav:kl)=0.
      tt2(1:ifull_g,kbotdav:kl)=0.
      uu2(1:ifull_g,kbotdav:kl)=0.
      vv2(1:ifull_g,kbotdav:kl)=0.
      ww2(1:ifull_g,kbotdav:kl)=0.
      psls2(1:ifull_g)=0.
      sumwt(1:ifull_g)=1.e-20   ! for undefined panels
      emmin=sqrt(cutoff2)*ds/rearth
      print *,'schmidt,cutoff,kbotdav ',schmidt,sqrt(cutoff2),kbotdav 
      
      do j=1,il_g                ! doing x-filter on panels 1,2,4,5
       xxmax=xx(il_g*(6*il_g-1)+il_g+1-j)
       print *,'j,xxmax ',j,xxmax
       do n=1,4*il_g
        if(n<=il_g)iq=il_g*(il_g+j-1)+n                   ! panel 1
        if(n>il_g.and.n<=2*il_g)iq=il_g*(2*il_g+j-2)+n      ! panel 2
        if(n>2*il_g)iq=il_g*(2*il_g+n-1)+il_g+1-j           ! panel 4,5
        
        if (em_g(iq).gt.emmin) then ! MJT
        
        do n1=n,4*il_g
!        following test shows on sx6 don't use "do n1=m+1,4*il_g"
!        if(n==4*il_g)print *,'problem for i,n,n1 ',i,n,n1
         if(n1<=il_g)iq1=il_g*(il_g+j-1)+n1               ! panel 1
         if(n1>il_g.and.n1<=2*il_g)iq1=il_g*(2*il_g+j-2)+n1 ! panel 2
         if(n1>2*il_g)iq1=il_g*(2*il_g+n1-1)+il_g+1-j       ! panel 4,5
         dist1=abs(xx(iq)-xx(iq1))
         dist=min(dist1,xxmax-dist1)
         wt=exp(-4.5*dist*dist*cutoff2)
         wt1=wt/em_g(iq1)
         wt=wt/em_g(iq)
         if(n==n1)wt1=0.  ! so as not to add in twice
c        if(iq==10345.or.iq1==10345)
c    &     print *,'iq,iq1,n,n1,xx,xx1,dist1,dist,wt,wt1 ',         
c    &              iq,iq1,n,n1,xx(iq),xx(iq1),dist1,dist,wt,wt1 
         sumwt(iq)=sumwt(iq)+wt1
         sumwt(iq1)=sumwt(iq1)+wt
!        producing "x-filtered" version of pslb-psl etc
c        psls(iq)=psls(iq)+wt1*(pslb(iq1)-psl(iq1))
c        psls(iq1)=psls(iq1)+wt*(pslb(iq)-psl(iq))
         psls(iq)=psls(iq)+wt1*psla(iq1)
         psls(iq1)=psls(iq1)+wt*psla(iq)
         do k=kbotdav,kl
          qgg(iq,k)=qgg(iq,k)+wt1*qa(iq1,k)
          qgg(iq1,k)=qgg(iq1,k)+wt*qa(iq,k)
          tt(iq,k)=tt(iq,k)+wt1*ta(iq1,k)
          tt(iq1,k)=tt(iq1,k)+wt*ta(iq,k)
          uu(iq,k)=uu(iq,k)+wt1*ua(iq1,k)
          uu(iq1,k)=uu(iq1,k)+wt*ua(iq,k)
          vv(iq,k)=vv(iq,k)+wt1*va(iq1,k)
          vv(iq1,k)=vv(iq1,k)+wt*va(iq,k)
          ww(iq,k)=ww(iq,k)+wt1*wa(iq1,k)
          ww(iq1,k)=ww(iq1,k)+wt*wa(iq,k)
         enddo  ! k loop
c        print *,'n,n1,dist,wt,wt1 ',n,n1,dist,wt,wt1
        enddo   ! n1 loop
        else
          sumwt(iq)=1.
        end if
       enddo    ! n loop
      enddo     ! j loop      
      if(nud_uv==-1)then
        do iq=1,ifull_g
         psls2(iq)=psls(iq)/sumwt(iq)
         do k=kbotdav,kl
          qgg2(iq,k)=qgg(iq,k)/sumwt(iq)
          tt2(iq,k)=tt(iq,k)/sumwt(iq)
          uu2(iq,k)=uu(iq,k)/sumwt(iq)
          vv2(iq,k)=vv(iq,k)/sumwt(iq)
          ww2(iq,k)=ww(iq,k)/sumwt(iq)
         enddo
        enddo
      else  ! original fast scheme
        do iq=1,ifull_g
         if(sumwt(iq).ne.1.e-20)then
           psla(iq)=psls(iq)/sumwt(iq)
           do k=kbotdav,kl
            qa(iq,k)=qgg(iq,k)/sumwt(iq)
            ta(iq,k)=tt(iq,k)/sumwt(iq)
            ua(iq,k)=uu(iq,k)/sumwt(iq)
            va(iq,k)=vv(iq,k)/sumwt(iq)
            wa(iq,k)=ww(iq,k)/sumwt(iq)
           enddo
         endif  ! (sumwt(iq).ne.1.e-20)
        enddo
      endif  ! (nud_uv==-1) .. else ..
      
      qgg(1:ifull_g,kbotdav:kl)=0.
      tt(1:ifull_g,kbotdav:kl)=0.
      uu(1:ifull_g,kbotdav:kl)=0.
      vv(1:ifull_g,kbotdav:kl)=0.
      ww(1:ifull_g,kbotdav:kl)=0.
      psls(1:ifull_g)=0.
      sumwt(1:ifull_g)=1.e-20   ! for undefined panels
      
      do i=1,il_g                ! doing y-filter on panels 0,1,3,4
       yymax=yy(il_g*(5*il_g-i+1))  
       do n=1,4*il_g
        if(n<=2*il_g)iq=il_g*(n-1)+i                      ! panel 0,1
        if(n>2*il_g.and.n<=3*il_g)iq=il_g*(4*il_g-i-2)+n      ! panel 3
        if(n>3*il_g)iq=il_g*(5*il_g-i-3)+n                  ! panel 4       
        if (em_g(iq).gt.emmin) then       
        do n1=n,4*il_g
         if(n1<=2*il_g)iq1=il_g*(n1-1)+i                  ! panel 0,1
         if(n1>2*il_g.and.n1<=3*il_g)iq1=il_g*(4*il_g-i-2)+n1 ! panel 3
         if(n1>3*il_g)iq1=il_g*(5*il_g-i-3)+n1              ! panel 4
         dist1=abs(yy(iq)-yy(iq1))
         dist=min(dist1,yymax-dist1)
         wt=exp(-4.5*dist*dist*cutoff2)
         wt1=wt/em_g(iq1)
         wt=wt/em_g(iq)
         if(n==n1)wt1=0.  ! so as not to add in twice
         sumwt(iq)=sumwt(iq)+wt1
         sumwt(iq1)=sumwt(iq1)+wt
!        producing "y-filtered" version of pslb-psl etc
         psls(iq)=psls(iq)+wt1*psla(iq1)
         psls(iq1)=psls(iq1)+wt*psla(iq)
         do k=kbotdav,kl
          qgg(iq,k)=qgg(iq,k)+wt1*qa(iq1,k)
          qgg(iq1,k)=qgg(iq1,k)+wt*qa(iq,k)
          tt(iq,k)=tt(iq,k)+wt1*ta(iq1,k)
          tt(iq1,k)=tt(iq1,k)+wt*ta(iq,k)
          uu(iq,k)=uu(iq,k)+wt1*ua(iq1,k)
          uu(iq1,k)=uu(iq1,k)+wt*ua(iq,k)
          vv(iq,k)=vv(iq,k)+wt1*va(iq1,k)
          vv(iq1,k)=vv(iq1,k)+wt*va(iq,k)
          ww(iq,k)=ww(iq,k)+wt1*wa(iq1,k)
          ww(iq1,k)=ww(iq1,k)+wt*wa(iq,k)
         enddo  ! k loop
        enddo   ! n1 loop
        else
          sumwt(iq)=1.
        end if
       enddo    ! n loop
      enddo     ! i loop
      if(nud_uv==-1)then
        do iq=1,ifull_g
         psls2(iq)=psls2(iq)+psls(iq)/sumwt(iq)
         do k=kbotdav,kl
          qgg2(iq,k)=qgg2(iq,k)+qgg(iq,k)/sumwt(iq)
          tt2(iq,k)=tt2(iq,k)+tt(iq,k)/sumwt(iq)
          uu2(iq,k)=uu2(iq,k)+uu(iq,k)/sumwt(iq)
          vv2(iq,k)=vv2(iq,k)+vv(iq,k)/sumwt(iq)
          ww2(iq,k)=ww2(iq,k)+ww(iq,k)/sumwt(iq)
         enddo
        enddo
      else  ! original fast scheme
        do iq=1,ifull_g
         if(sumwt(iq).ne.1.e-20)then
           psla(iq)=psls(iq)/sumwt(iq)
           do k=kbotdav,kl
            qa(iq,k)=qgg(iq,k)/sumwt(iq)
            ta(iq,k)=tt(iq,k)/sumwt(iq)
            ua(iq,k)=uu(iq,k)/sumwt(iq)
            va(iq,k)=vv(iq,k)/sumwt(iq)
            wa(iq,k)=ww(iq,k)/sumwt(iq)
           enddo
         endif  ! (sumwt(iq).ne.1.e-20)
        enddo
      endif  ! (nud_uv==-1) .. else ..

      if(mbd.ge.0) then
       qgg(1:ifull_g,kbotdav:kl)=0.
       tt(1:ifull_g,kbotdav:kl)=0.
       uu(1:ifull_g,kbotdav:kl)=0.
       vv(1:ifull_g,kbotdav:kl)=0.
       ww(1:ifull_g,kbotdav:kl)=0.
       psls(1:ifull_g)=0.
       sumwt(1:ifull_g)=1.e-20   ! for undefined panels
    
       do j=1,il_g                ! doing "z"-filter on panels 0,2,3,5
        zzmax=zz(5*il_g*il_g+il_g*j)
        print *,'j,zzmax ',j,zzmax
        do n=1,4*il_g
         if(n<=il_g)iq=il_g*(j-1)+n                     ! panel 0
         if(n>il_g.and.n<=3*il_g)iq=il_g*(il_g+n-1)+il_g+1-j  ! panel 2,3
         if(n>3*il_g)iq=il_g*(5*il_g+j-4)+n               ! panel 5
        
         if (em_g(iq).gt.emmin) then ! MJT
        
         do n1=n,4*il_g
          if(n1<=il_g)iq1=il_g*(j-1)+n1                     ! panel 0
          if(n1>il_g.and.n1<=3*il_g)iq1=il_g*(il_g+n1-1)+il_g+1-j ! panel 2,3
          if(n1>3*il_g)iq1=il_g*(5*il_g+j-4)+n1               ! panel 5
          dist1=abs(zz(iq)-zz(iq1))
          dist=min(dist1,zzmax-dist1)
          wt=exp(-4.5*dist*dist*cutoff2)
          wt1=wt/em_g(iq1)
          wt=wt/em_g(iq)
          if(n==n1)wt1=0.  ! so as not to add in twice
          sumwt(iq)=sumwt(iq)+wt1
          sumwt(iq1)=sumwt(iq1)+wt
!         producing "z"-filtered version of pslb-psl etc
          psls(iq)=psls(iq)+wt1*psla(iq1)
          psls(iq1)=psls(iq1)+wt*psla(iq)
          do k=kbotdav,kl
           qgg(iq,k)=qgg(iq,k)+wt1*qa(iq1,k)
           qgg(iq1,k)=qgg(iq1,k)+wt*qa(iq,k)
           tt(iq,k)=tt(iq,k)+wt1*ta(iq1,k)
           tt(iq1,k)=tt(iq1,k)+wt*ta(iq,k)
           uu(iq,k)=uu(iq,k)+wt1*ua(iq1,k)
           uu(iq1,k)=uu(iq1,k)+wt*ua(iq,k)
           vv(iq,k)=vv(iq,k)+wt1*va(iq1,k)
           vv(iq1,k)=vv(iq1,k)+wt*va(iq,k)
           ww(iq,k)=ww(iq,k)+wt1*wa(iq1,k)
           ww(iq1,k)=ww(iq1,k)+wt*wa(iq,k)
          enddo  ! k loop
         enddo   ! n1 loop
         else
           sumwt(iq)=1.
         end if
        enddo    ! n loop
       enddo     ! j loop      
      if(nud_uv==-1)then
        print *,'in nestinb nud_uv ',nud_uv
        do iq=1,ifull_g
         psls2(iq)=psls2(iq)+psls(iq)/sumwt(iq)
         do k=kbotdav,kl
          qgg2(iq,k)=qgg2(iq,k)+qgg(iq,k)/sumwt(iq)
          tt2(iq,k)=tt2(iq,k)+tt(iq,k)/sumwt(iq)
          uu2(iq,k)=uu2(iq,k)+uu(iq,k)/sumwt(iq)
          vv2(iq,k)=vv2(iq,k)+vv(iq,k)/sumwt(iq)
          ww2(iq,k)=ww2(iq,k)+ww(iq,k)/sumwt(iq)
         enddo
        enddo
        psla(1:ifull_g)=.5*psls2(1:ifull_g)
        qa(1:ifull_g,kbotdav:kl)=.5*qgg2(1:ifull_g,kbotdav:kl)
        ta(1:ifull_g,kbotdav:kl)=.5*tt2(1:ifull_g,kbotdav:kl)
        ua(1:ifull_g,kbotdav:kl)=.5*uu2(1:ifull_g,kbotdav:kl)
        va(1:ifull_g,kbotdav:kl)=.5*vv2(1:ifull_g,kbotdav:kl)
        wa(1:ifull_g,kbotdav:kl)=.5*ww2(1:ifull_g,kbotdav:kl)
      else  ! original fast scheme
        print *,'in nestinb  nud_uv ',nud_uv
        do iq=1,ifull_g
         if(sumwt(iq).ne.1.e-20)then
           psla(iq)=psls(iq)/sumwt(iq)
           do k=kbotdav,kl
            qa(iq,k)=qgg(iq,k)/sumwt(iq)
            ta(iq,k)=tt(iq,k)/sumwt(iq)
            ua(iq,k)=uu(iq,k)/sumwt(iq)
            va(iq,k)=vv(iq,k)/sumwt(iq)
            wa(iq,k)=ww(iq,k)/sumwt(iq)
           enddo
         endif  ! (sumwt(iq).ne.1.e-20)
        enddo
      endif  ! (nud_uv==-1) .. else ..
      end if ! (mbd.ge.0)

      return
      end subroutine fastspec


      !---------------------------------------------------------------------------------
      ! Slow 2D spectral downscaling - MPI version
      subroutine slowspecmpi(myid,c,psls,uu,vv,ww,tt,qgg)
      
      implicit none
      
      include 'newmpar.h'   ! ifull_g,kl
      include 'const_phys.h' ! rearth,pi,tpi
      include 'map_g.h'     ! em_g
      include 'parm.h'      ! ds,kbotdav
      include 'xyzinfo_g.h' ! x_g,y_g,z_g
      include 'mpif.h'

      integer, intent(in) :: myid
      real, intent(in) :: c
      real, dimension(ifull_g), intent(inout) :: psls
      real, dimension(ifull_g,kbotdav:kl), intent(inout) :: uu,vv,ww
      real, dimension(ifull_g,kbotdav:kl), intent(inout) :: tt,qgg
      real, dimension(ifull_g) :: pp,r
      real, dimension(ifull_g,kbotdav:kl) :: pu,pv,pw,pt,pq
      real, dimension(ifull_g*(kl-kbotdav+1)) :: dd
      real :: rmaxsq,csq,emmin,psum
      integer :: iq,ns,ne,k,itag=0,ierr,iproc,ix,iy
      integer, dimension(MPI_STATUS_SIZE) :: status

      emmin=c*ds/rearth
      rmaxsq=1./c**2
      csq=-4.5*c**2

      if (myid == 0) then
        print *,"Send global arrays to all processors"
        do iproc=1,nproc-1
          if(nud_p>0)call MPI_SSend(psls(:),ifull_g,MPI_REAL,iproc,
     &                      itag,MPI_COMM_WORLD,ierr)
          if(nud_uv>0)then
            ix=0
            do k=kbotdav,kl
              dd(ix+1:ix+ifull_g)=uu(:,k)
              ix=ix+ifull_g
            end do
            call MPI_SSend(dd(1:ix),ix,MPI_REAL,iproc,itag,
     &             MPI_COMM_WORLD,ierr)    
            ix=0
            do k=kbotdav,kl
              dd(ix+1:ix+ifull_g)=vv(:,k)
              ix=ix+ifull_g
            end do
            call MPI_SSend(dd(1:ix),ix,MPI_REAL,iproc,itag,
     &             MPI_COMM_WORLD,ierr)    
            ix=0
            do k=kbotdav,kl
              dd(ix+1:ix+ifull_g)=ww(:,k)
              ix=ix+ifull_g
            end do
            call MPI_SSend(dd(1:ix),ix,MPI_REAL,iproc,itag,
     &             MPI_COMM_WORLD,ierr)    
          end if
          if(nud_t>0)then
            ix=0
            do k=kbotdav,kl
              dd(ix+1:ix+ifull_g)=tt(:,k)
              ix=ix+ifull_g
            end do
            call MPI_SSend(dd(1:ix),ix,MPI_REAL,iproc,itag,
     &             MPI_COMM_WORLD,ierr) 
          end if
          if(nud_q>0)then
            ix=0
            do k=kbotdav,kl
              dd(ix+1:ix+ifull_g)=qgg(:,k)
              ix=ix+ifull_g
            end do
            call MPI_SSend(dd(1:ix),ix,MPI_REAL,iproc,itag,
     &             MPI_COMM_WORLD,ierr) 
          end if
        end do
      else
        if(nud_p>0)then
         call MPI_Recv(psls(:),ifull_g,MPI_REAL,0,itag,
     &                     MPI_COMM_WORLD,status,ierr)
        end if
        iy=ifull_g*(kl-kbotdav+1)
        if(nud_uv>0)then
          call MPI_Recv(dd(1:iy),iy,MPI_REAL,0,itag,
     &           MPI_COMM_WORLD,status,ierr)
          ix=0
          do k=kbotdav,kl
            uu(:,k)=dd(ix+1:ix+ifull_g)
            ix=ix+ifull_g
          end do
          call MPI_Recv(dd(1:iy),iy,MPI_REAL,0,itag,
     &           MPI_COMM_WORLD,status,ierr)
          ix=0
          do k=kbotdav,kl
            vv(:,k)=dd(ix+1:ix+ifull_g)
            ix=ix+ifull_g
          end do
          call MPI_Recv(dd(1:iy),iy,MPI_REAL,0,itag,
     &           MPI_COMM_WORLD,status,ierr)
          ix=0
          do k=kbotdav,kl
            ww(:,k)=dd(ix+1:ix+ifull_g)
            ix=ix+ifull_g
          end do
        end if
        if(nud_t>0)then
          call MPI_Recv(dd(1:iy),iy,MPI_REAL,0,itag,
     &           MPI_COMM_WORLD,status,ierr)
          ix=0
          do k=kbotdav,kl
            tt(:,k)=dd(ix+1:ix+ifull_g)
            ix=ix+ifull_g
          end do
        end if
        if(nud_q>0)then
          call MPI_Recv(dd(1:iy),iy,MPI_REAL,0,itag,
     &           MPI_COMM_WORLD,status,ierr)
          ix=0
          do k=kbotdav,kl
            qgg(:,k)=dd(ix+1:ix+ifull_g)
            ix=ix+ifull_g
          end do
        end if
      end if
    
      call procdiv(ns,ne,ifull_g,nproc,myid)
      if (myid == 0) print *,"Process filter"
      
      do iq=ns,ne
        if (em_g(iq).gt.emmin) then
          r(:)=x_g(iq)*x_g(:)+y_g(iq)*y_g(:)+z_g(iq)*z_g(:)
          r(:)=acos(max(min(r(:),1.),-1.))**2
          r(:)=exp(r(:)*csq)/(em_g(:)**2) ! redefine r(:) as wgt(:)
          psum=sum(r(:))
          pp(iq)=sum(r(:)*psls(:))/psum
          do k=kbotdav,kl
            pu(iq,k)=sum(r(:)*uu(:,k))/psum
            pv(iq,k)=sum(r(:)*vv(:,k))/psum
            pw(iq,k)=sum(r(:)*ww(:,k))/psum
            pt(iq,k)=sum(r(:)*tt(:,k))/psum
            pq(iq,k)=sum(r(:)*qgg(:,k))/psum
          end do
        else
          pp(iq)=psls(iq)
          pu(iq,:)=uu(iq,:)
          pv(iq,:)=vv(iq,:)
          pw(iq,:)=ww(iq,:)
          pt(iq,:)=tt(iq,:)
          pq(iq,:)=qgg(iq,:)
        end if
      end do
 
      psls(ns:ne)=pp(ns:ne)
      uu(ns:ne,:)=pu(ns:ne,:)
      vv(ns:ne,:)=pv(ns:ne,:)
      ww(ns:ne,:)=pw(ns:ne,:)
      tt(ns:ne,:)=pt(ns:ne,:)
      qgg(ns:ne,:)=pq(ns:ne,:)
          
          
      itag=itag+1
      if (myid == 0) then
        print *,"Receive array sections from all processors"
        do iproc=1,nproc-1
          call procdiv(ns,ne,ifull_g,nproc,iproc)
          if(nud_p>0)call MPI_Recv(psls(ns:ne),ne-ns+1,MPI_REAL,iproc
     &                      ,itag,MPI_COMM_WORLD,status,ierr)
          iy=(ne-ns+1)*(kl-kbotdav+1)
          if(nud_uv>0)then
            call MPI_Recv(dd(1:iy),iy,MPI_REAL,iproc,itag,
     &             MPI_COMM_WORLD,status,ierr)
            ix=0
            do k=kbotdav,kl
              uu(ns:ne,k)=dd(ix+1:ix+ne-ns+1)
              ix=ix+ne-ns+1
            end do
            call MPI_Recv(dd(1:iy),iy,MPI_REAL,iproc,itag,
     &             MPI_COMM_WORLD,status,ierr)
            ix=0
            do k=kbotdav,kl
              vv(ns:ne,k)=dd(ix+1:ix+ne-ns+1)
              ix=ix+ne-ns+1
            end do
            call MPI_Recv(dd(1:iy),iy,MPI_REAL,iproc,itag,
     &             MPI_COMM_WORLD,status,ierr)
            ix=0
            do k=kbotdav,kl
              ww(ns:ne,k)=dd(ix+1:ix+ne-ns+1)
              ix=ix+ne-ns+1
            end do
          end if
          if(nud_t>0)then
            call MPI_Recv(dd(1:iy),iy,MPI_REAL,iproc,itag,
     &             MPI_COMM_WORLD,status,ierr)
            ix=0
            do k=kbotdav,kl
              tt(ns:ne,k)=dd(ix+1:ix+ne-ns+1)
              ix=ix+ne-ns+1
            end do
          end if
          if(nud_q>0)then
            call MPI_Recv(dd(1:iy),iy,MPI_REAL,iproc,itag,
     &             MPI_COMM_WORLD,status,ierr)
            ix=0
            do k=kbotdav,kl
              qgg(ns:ne,k)=dd(ix+1:ix+ne-ns+1)
              ix=ix+ne-ns+1
            end do
          end if
        end do
      else
        if(nud_p>0) call MPI_SSend(psls(ns:ne),ne-ns+1,MPI_REAL,0,
     &                     itag,MPI_COMM_WORLD,ierr)
        if(nud_uv>0)then
          ix=0
          do k=kbotdav,kl
            dd(ix+1:ix+ne-ns+1)=uu(ns:ne,k)
            ix=ix+ne-ns+1
          end do
          call MPI_SSend(dd(1:iy),iy,MPI_REAL,0,itag,
     &           MPI_COMM_WORLD,ierr)
          ix=0
          do k=kbotdav,kl
            dd(ix+1:ix+ne-ns+1)=vv(ns:ne,k)
            ix=ix+ne-ns+1
          end do
          call MPI_SSend(dd(1:iy),iy,MPI_REAL,0,itag,
     &           MPI_COMM_WORLD,ierr)
          ix=0
          do k=kbotdav,kl
            dd(ix+1:ix+ne-ns+1)=ww(ns:ne,k)
            ix=ix+ne-ns+1
          end do
          call MPI_SSend(dd(1:iy),iy,MPI_REAL,0,itag,
     &           MPI_COMM_WORLD,ierr)
        end if
        if(nud_t>0)then
          ix=0
          do k=kbotdav,kl
            dd(ix+1:ix+ne-ns+1)=tt(ns:ne,k)
            ix=ix+ne-ns+1
          end do
          call MPI_SSend(dd(1:iy),iy,MPI_REAL,0,itag,
     &           MPI_COMM_WORLD,ierr)
        end if
        if(nud_q>0)then
          ix=0
          do k=kbotdav,kl
            dd(ix+1:ix+ne-ns+1)=qgg(ns:ne,k)
            ix=ix+ne-ns+1
          end do
          call MPI_SSend(dd(1:iy),iy,MPI_REAL,0,itag,
     &           MPI_COMM_WORLD,ierr)
        end if
      end if

      return
      end subroutine slowspecmpi
      !---------------------------------------------------------------------------------

      !---------------------------------------------------------------------------------
      ! Four pass spectral downscaling (symmetric)
      subroutine fourspecmpi(myid,c,psls,uu,vv,ww,tt,qgg)
      
      implicit none
      
      include 'newmpar.h'   ! ifull_g,kl
      include 'const_phys.h' ! rearth,pi,tpi
      include 'map_g.h'     ! em_g
      include 'parm.h'      ! ds,kbotdav
      include 'xyzinfo_g.h' ! x_g,y_g,z_g
      include 'mpif.h'
      
      integer, intent(in) :: myid
      real, intent(in) :: c
      real, dimension(ifull_g), intent(inout) :: psls
      real, dimension(ifull_g,kbotdav:kl), intent(inout) :: uu,vv,ww
      real, dimension(ifull_g,kbotdav:kl), intent(inout) :: tt,qgg
      real, dimension(ifull_g) :: qp,zp,qsum
      real, dimension(ifull_g,kbotdav:kl) :: qu,qv,qw,qt,qq
      real, dimension(ifull_g,kbotdav:kl) :: zu,zv,zw,zt,zq
      real, dimension(4*il_g,kbotdav:kl) :: pu,pv,pw,pt,pq
      real, dimension(4*il_g,kbotdav:kl) :: au,av,aw,at,aq
      real, dimension(4*il_g) :: pp,ap,psum,asum,ra,ema,xa,ya,za
      real, dimension(4*il_g*il_g*(kl-kbotdav+1)) :: dd
      real :: rmaxsq,csq,emmin
      integer :: iq,j,ipass,ppass,n,ix,iy
      integer :: me,ne,ns,nne,nns,iproc,k,itag=0,ierr
      integer, dimension(MPI_STATUS_SIZE) :: status
      integer, dimension(0:3) :: maps
      integer, dimension(4*il_g,il_g) :: igrd
      
      maps(:)=(/ il_g, il_g, 4*il_g, 3*il_g /) 
 
      emmin=c*ds/rearth
      rmaxsq=1./c**2
      csq=-4.5*c**2
      call procdiv(ns,ne,il_g,nproc,myid)

      do ppass=0,5

        qp(:)=psls(:)
        qu(:,:)=uu(:,:)
        qv(:,:)=vv(:,:)
        qw(:,:)=ww(:,:)
        qt(:,:)=tt(:,:)
        qq(:,:)=qgg(:,:)
        qsum(:)=1.   

        do ipass=0,3
          me=maps(ipass)

          if (myid == 0) then
            !if(nmaxpr==1)print *,"6/4 pass ",ppass,ipass
            print *,"6/4 pass ",ppass,ipass
            do iproc=1,nproc-1
              call procdiv(nns,nne,il_g,nproc,iproc)
              do j=nns,nne
                do n=1,me
                  call getiqx(iq,j,n,ipass,ppass,il_g)
                  igrd(n,j)=iq
                end do
              end do
              ix=0
              do j=nns,nne
                do n=1,me
                  ix=ix+1
                  dd(ix)=qsum(igrd(n,j))
                end do
              end do
              call MPI_SSend(dd(1:ix),ix,MPI_REAL,iproc,itag,
     &               MPI_COMM_WORLD,ierr)    
              if(nud_p>0)then
                ix=0
                do j=nns,nne
                  do n=1,me
                    ix=ix+1
                    dd(ix)=qp(igrd(n,j))
                  end do
                end do
                call MPI_SSend(dd(1:ix),ix,MPI_REAL,iproc,itag,
     &                 MPI_COMM_WORLD,ierr)
              end if
              if(nud_uv>0)then
                ix=0
                do k=kbotdav,kl    
                  do j=nns,nne
                    do n=1,me
                      ix=ix+1
                      dd(ix)=qu(igrd(n,j),k)
                    end do
                  end do
                end do
                call MPI_SSend(dd(1:ix),ix,MPI_REAL,iproc,itag,
     &                 MPI_COMM_WORLD,ierr)
                ix=0
                do k=kbotdav,kl    
                  do j=nns,nne
                    do n=1,me
                      ix=ix+1
                      dd(ix)=qv(igrd(n,j),k)
                    end do
                  end do
                end do
                call MPI_SSend(dd(1:ix),ix,MPI_REAL,iproc,itag,
     &                 MPI_COMM_WORLD,ierr)
                ix=0
                do k=kbotdav,kl    
                  do j=nns,nne
                    do n=1,me
                      ix=ix+1
                      dd(ix)=qw(igrd(n,j),k)
                    end do
                  end do
                end do
                call MPI_SSend(dd(1:ix),ix,MPI_REAL,iproc,itag,
     &                 MPI_COMM_WORLD,ierr)
              end if
              if(nud_t>0)then
                ix=0
                do k=kbotdav,kl    
                  do j=nns,nne
                    do n=1,me
                      ix=ix+1
                      dd(ix)=qt(igrd(n,j),k)
                    end do
                  end do
                end do
                call MPI_SSend(dd(1:ix),ix,MPI_REAL,iproc,itag,
     &                 MPI_COMM_WORLD,ierr)
              end if
              if(nud_q>0)then
                ix=0
                do k=kbotdav,kl    
                  do j=nns,nne
                    do n=1,me
                      ix=ix+1
                      dd(ix)=qq(igrd(n,j),k)
                    end do
                  end do
                end do
                call MPI_SSend(dd(1:ix),ix,MPI_REAL,iproc,itag,
     &                 MPI_COMM_WORLD,ierr)
              end if
            end do
            do j=ns,ne
              do n=1,me
                call getiqx(iq,j,n,ipass,ppass,il_g)
                igrd(n,j)=iq
              end do
            end do
          else
            do j=ns,ne
              do n=1,me
                call getiqx(iq,j,n,ipass,ppass,il_g)
                igrd(n,j)=iq
              end do
            end do
            iy=me*(ne-ns+1)
            call MPI_Recv(dd(1:iy),iy,MPI_REAL,0,itag,
     &             MPI_COMM_WORLD,status,ierr)
            ix=0
            do j=ns,ne
              do n=1,me
                ix=ix+1
                qsum(igrd(n,j))=dd(ix)
              end do
            end do
            if(nud_p>0)then
              call MPI_Recv(dd(1:iy),iy,MPI_REAL,0,itag,
     &               MPI_COMM_WORLD,status,ierr)
              ix=0
              do j=ns,ne
                do n=1,me
                  ix=ix+1
                  qp(igrd(n,j))=dd(ix)
                end do
              end do
            endif
            iy=me*(ne-ns+1)*(kl-kbotdav+1)	    
            if(nud_uv>0)then
              call MPI_Recv(dd(1:iy),iy,MPI_REAL,0,itag,
     &               MPI_COMM_WORLD,status,ierr)
              ix=0
              do k=kbotdav,kl
                do j=ns,ne
                  do n=1,me
                    ix=ix+1
                    qu(igrd(n,j),k)=dd(ix)
                  end do
                end do
              end do
              call MPI_Recv(dd(1:iy),iy,MPI_REAL,0,itag,
     &               MPI_COMM_WORLD,status,ierr)
              ix=0
              do k=kbotdav,kl
                do j=ns,ne
                  do n=1,me
                    ix=ix+1
                    qv(igrd(n,j),k)=dd(ix)
                  end do
                end do
              end do
              call MPI_Recv(dd(1:iy),iy,MPI_REAL,0,itag,
     &               MPI_COMM_WORLD,status,ierr)
              ix=0
              do k=kbotdav,kl
                do j=ns,ne
                  do n=1,me
                    ix=ix+1
                    qw(igrd(n,j),k)=dd(ix)
                  end do
                end do
              end do
            end if
            if(nud_t>0)then
              call MPI_Recv(dd(1:iy),iy,MPI_REAL,0,itag,
     &               MPI_COMM_WORLD,status,ierr)
              ix=0
              do k=kbotdav,kl
                do j=ns,ne
                  do n=1,me
                    ix=ix+1
                    qt(igrd(n,j),k)=dd(ix)
                  end do
                end do
              end do
            end if
            if(nud_q>0)then
              call MPI_Recv(dd(1:iy),iy,MPI_REAL,0,itag,
     &               MPI_COMM_WORLD,status,ierr)
              ix=0
              do k=kbotdav,kl
                do j=ns,ne
                  do n=1,me
                    ix=ix+1
                    qq(igrd(n,j),k)=dd(ix)
                  end do
                end do
              end do
            end if
          end if

          do j=ns,ne
            ema(1:me)=em_g(igrd(1:me,j))
            asum(1:me)=qsum(igrd(1:me,j))
            ap(1:me)=qp(igrd(1:me,j))
            au(1:me,:)=qu(igrd(1:me,j),:)
            av(1:me,:)=qv(igrd(1:me,j),:)
            aw(1:me,:)=qw(igrd(1:me,j),:)
            at(1:me,:)=qt(igrd(1:me,j),:)
            aq(1:me,:)=qq(igrd(1:me,j),:)
            xa(1:me)=x_g(igrd(1:me,j))
            ya(1:me)=y_g(igrd(1:me,j))
            za(1:me)=z_g(igrd(1:me,j))
            do n=1,il_g
              if (ema(n).gt.emmin) then
                ra(1:me)=xa(n)*xa(1:me)+ya(n)*ya(1:me)+za(n)*za(1:me)
                ra(1:me)=acos(max(min(ra(1:me),1.),-1.))**2
                ra(1:me)=exp(ra(1:me)*csq)/(ema(1:me)**2) ! redefine ra(:) as wgt(:)
                psum(n)=sum(ra(1:me)*asum(1:me))
                pp(n)=sum(ra(1:me)*ap(1:me))
                do k=kbotdav,kl
                  pu(n,k)=sum(ra(1:me)*au(1:me,k))
                  pv(n,k)=sum(ra(1:me)*av(1:me,k))
                  pw(n,k)=sum(ra(1:me)*aw(1:me,k))
                  pt(n,k)=sum(ra(1:me)*at(1:me,k))
                  pq(n,k)=sum(ra(1:me)*aq(1:me,k))
                end do
              else
                psum(n)=asum(n)
                pp(n)=ap(n)
                pu(n,:)=au(n,:)
                pv(n,:)=av(n,:)
                pw(n,:)=aw(n,:)
                pt(n,:)=at(n,:)
                pq(n,:)=aq(n,:)
              end if
            end do
            qsum(igrd(1:il_g,j))=psum(1:il_g)
            qp(igrd(1:il_g,j))=pp(1:il_g)
            qu(igrd(1:il_g,j),:)=pu(1:il_g,:)
            qv(igrd(1:il_g,j),:)=pv(1:il_g,:)
            qw(igrd(1:il_g,j),:)=pw(1:il_g,:)
            qt(igrd(1:il_g,j),:)=pt(1:il_g,:)
            qq(igrd(1:il_g,j),:)=pq(1:il_g,:)
          end do
          
          itag=itag+1
          if (myid == 0) then
            do iproc=1,nproc-1
              call procdiv(nns,nne,il_g,nproc,iproc)
              do j=nns,nne
                do n=1,il_g
                  call getiqx(iq,j,n,ipass,ppass,il_g)
                  igrd(n,j)=iq
                end do
              end do
              iy=il_g*(nne-nns+1)	      
              call MPI_Recv(dd(1:iy),iy,MPI_REAL,iproc
     &               ,itag,MPI_COMM_WORLD,status,ierr)
              ix=0
              do j=nns,nne
                do n=1,il_g
                  ix=ix+1
                  qsum(igrd(n,j))=dd(ix)
                end do
              end do
              if(nud_p>0)then
                call MPI_Recv(dd(1:iy),iy,MPI_REAL,iproc,itag,
     &                 MPI_COMM_WORLD,status,ierr)
                ix=0
                do j=nns,nne
                  do n=1,il_g
                    ix=ix+1
                    qp(igrd(n,j))=dd(ix)
                  end do
                end do
              end if
              iy=il_g*(nne-nns+1)*(kl-kbotdav+1)
              if(nud_uv>0)then
                call MPI_Recv(dd(1:iy),iy,MPI_REAL,iproc
     &                 ,itag,MPI_COMM_WORLD,status,ierr)
                ix=0
                do k=kbotdav,kl
                  do j=nns,nne
                    do n=1,il_g
                      ix=ix+1
                      qu(igrd(n,j),k)=dd(ix)
                    end do
                  end do
                end do
                call MPI_Recv(dd(1:iy),iy,MPI_REAL,iproc
     &                 ,itag,MPI_COMM_WORLD,status,ierr)
                ix=0
                do k=kbotdav,kl
                  do j=nns,nne
                    do n=1,il_g
                      ix=ix+1
                      qv(igrd(n,j),k)=dd(ix)
                    end do
                  end do
                end do
                call MPI_Recv(dd(1:iy),iy,MPI_REAL,iproc
     &                 ,itag,MPI_COMM_WORLD,status,ierr)
                ix=0
                do k=kbotdav,kl
                  do j=nns,nne
                    do n=1,il_g
                      ix=ix+1
                      qw(igrd(n,j),k)=dd(ix)
                    end do
                  end do
                end do
              end if
              if(nud_t>0)then
                call MPI_Recv(dd(1:iy),iy,MPI_REAL,iproc
     &                 ,itag,MPI_COMM_WORLD,status,ierr)
                ix=0
                do k=kbotdav,kl
                  do j=nns,nne
                    do n=1,il_g
                      ix=ix+1
                      qt(igrd(n,j),k)=dd(ix)
                    end do
                  end do
                end do
              end if
              if(nud_q>0)then
                call MPI_Recv(dd(1:iy),iy,MPI_REAL,iproc
     &                 ,itag,MPI_COMM_WORLD,status,ierr)
                ix=0
                do k=kbotdav,kl
                  do j=nns,nne
                    do n=1,il_g
                      ix=ix+1
                      qq(igrd(n,j),k)=dd(ix)
                    end do
                  end do
                end do
              end if
            end do
          else
            ix=0
            do j=ns,ne
              do n=1,il_g
                ix=ix+1
                dd(ix)=qsum(igrd(n,j))
              end do
            end do
            call MPI_SSend(dd(1:ix),ix,MPI_REAL,0,itag,
     &             MPI_COMM_WORLD,ierr)
            if(nud_p>0)then
              ix=0
              do j=ns,ne
                do n=1,il_g
                  ix=ix+1
                  dd(ix)=qp(igrd(n,j))
                end do
              end do
              call MPI_SSend(dd(1:ix),ix,MPI_REAL,0,itag,
     &               MPI_COMM_WORLD,ierr)
            end if
            if(nud_uv>0)then
              ix=0
              do k=kbotdav,kl
                do j=ns,ne
                  do n=1,il_g
                    ix=ix+1
                    dd(ix)=qu(igrd(n,j),k)
                  end do
                end do
              end do
              call MPI_SSend(dd(1:ix),ix,MPI_REAL,0,itag,
     &               MPI_COMM_WORLD,ierr)
              ix=0
              do k=kbotdav,kl
                do j=ns,ne
                  do n=1,il_g
                    ix=ix+1
                    dd(ix)=qv(igrd(n,j),k)
                  end do
                end do
              end do
              call MPI_SSend(dd(1:ix),ix,MPI_REAL,0,itag,
     &               MPI_COMM_WORLD,ierr)
              ix=0
              do k=kbotdav,kl
                do j=ns,ne
                  do n=1,il_g
                    ix=ix+1
                    dd(ix)=qw(igrd(n,j),k)
                  end do
                end do
              end do
              call MPI_SSend(dd(1:ix),ix,MPI_REAL,0,itag,
     &               MPI_COMM_WORLD,ierr)
            end if
            if(nud_t>0)then
              ix=0
              do k=kbotdav,kl
                do j=ns,ne
                  do n=1,il_g
                    ix=ix+1
                    dd(ix)=qt(igrd(n,j),k)
                  end do
                end do
              end do
              call MPI_SSend(dd(1:ix),ix,MPI_REAL,0,itag,
     &               MPI_COMM_WORLD,ierr)
            end if
            if(nud_q>0)then
              ix=0
              do k=kbotdav,kl
                do j=ns,ne
                  do n=1,il_g
                    ix=ix+1
                    dd(ix)=qq(igrd(n,j),k)
                  end do
                end do
              end do
              call MPI_SSend(dd(1:ix),ix,MPI_REAL,0,itag,
     &               MPI_COMM_WORLD,ierr)
            end if
          end if
        end do

        if (myid==0) then
          nns=ppass*il_g*il_g+1
          nne=(ppass+1)*il_g*il_g
          zp(nns:nne)=qp(nns:nne)/qsum(nns:nne)
          do k=kbotdav,kl
            zu(nns:nne,k)=qu(nns:nne,k)/qsum(nns:nne)
            zv(nns:nne,k)=qv(nns:nne,k)/qsum(nns:nne)
            zw(nns:nne,k)=qw(nns:nne,k)/qsum(nns:nne)
            zt(nns:nne,k)=qt(nns:nne,k)/qsum(nns:nne)
            zq(nns:nne,k)=qq(nns:nne,k)/qsum(nns:nne)
          end do
        end if

      end do
      
      psls(:)=zp(:)
      uu(:,:)=zu(:,:)
      vv(:,:)=zv(:,:)
      ww(:,:)=zw(:,:)
      tt(:,:)=zt(:,:)
      qgg(:,:)=zq(:,:)
      
      return
      end subroutine fourspecmpi
      !---------------------------------------------------------------------------------

      !---------------------------------------------------------------------------------
      subroutine getiqx(iq,j,n,ipass,ppass,il_g)
      
      implicit none
      
      integer, intent(out) :: iq
      integer, intent(in) :: j,n,ipass,ppass,il_g
      
      select case(ppass*100+ipass*10+(n-1)/il_g)
        case(0,310,530)
          iq=il_g*(5*il_g+n)+1-j      ! panel 5   - x pass
        case(10,230,300)
          iq=il_g*(2*il_g+j-1)+n      ! panel 2   - x pass
        case(20,21)
          iq=il_g*(n-1)+j             ! panel 0,1 - y pass
        case(22,432)
          iq=il_g*(4*il_g-j-2)+n      ! panel 3   - y pass
        case(23)
          iq=il_g*(5*il_g-j-3)+n      ! panel 4   - y pass
        case(30,100,410)
          iq=il_g*(j-1)+n             ! panel 0   - z pass
        case(31)
          iq=il_g*(il_g+n)+1-j        ! panel 2   - z pass
        case(32,222)
          iq=il_g*(5*il_g+j-3)+n      ! panel 5   - z pass
        case(110,231,330,400)
          iq=il_g*(3*il_g+n)+1-j      ! panel 3   - z pass
        case(120)
          iq=il_g*(il_g+j-1)+n        ! panel 1   - x pass
        case(121)
          iq=il_g*(2*il_g+j-2)+n      ! panel 2   - x pass
        case(122,123,220,221)
          iq=il_g*(2*il_g+n)+1-j      ! panel 4,5 - x pass ! panel 2,3 - z pass
        case(130,200,510)
          iq=il_g*(il_g+n-1)+j        ! panel 1   - y pass
        case(131)
          iq=il_g*(4*il_g-j-1)+n      ! panel 3   - y pass
        case(132,322,323)
          iq=il_g*(-2*il_g+n-1)+j     ! panel 0,1 - y pass
        case(210,430,500)
          iq=il_g*(5*il_g-j)+n        ! panel 4   - y pass
        case(223)
          iq=il_g*(j-4)+n             ! panel 0   - z pass
        case(232,422)
          iq=il_g*(il_g+j-3)+n        ! panel 1   - x pass
        case(320)
          iq=il_g*(4*il_g-j)+n        ! panel 3   - y pass
        case(321)
          iq=il_g*(5*il_g-j-1)+n      ! panel 4   - y pass
        case(331)
          iq=il_g*(5*il_g+j-2)+n      ! panel 5   - z pass
        case(332,522,523)
          iq=il_g*n+1-j               ! panel 2,3 - z pass 
        case(420,421)
          iq=il_g*(4*il_g+n)+1-j      ! panel 4,5 - x pass
        case(423)
          iq=il_g*(2*il_g+j-4)+n      ! panel 2   - x pass
        case(431)
          iq=il_g*(-il_g+n-1)+j       ! panel 0   - y pass
        case(520)
          iq=il_g*(5*il_g+j-1)+n      ! panel 5   - z pass
        case(521)
          iq=il_g*(j-2)+n             ! panel 0   - z pass
        case(531)
          iq=il_g*(il_g+j-2)+n        ! panel 1   - x pass
        case(532)
          iq=il_g*(2*il_g+n)+1-j      ! panel 4   - x pass
      end select

      end subroutine getiqx
      !---------------------------------------------------------------------------------

      !---------------------------------------------------------------------------------
      subroutine procdiv(ns,ne,ifull_g,nproc,myid)
      
      implicit none
      
      integer, intent(in) :: ifull_g,nproc,myid
      integer, intent(out) :: ns,ne
      integer npt,resid
      
      npt=ifull_g/nproc
      resid=mod(ifull_g,nproc)
      if ((myid+1).le.resid) then
        ns=myid*(npt+1)+1
        ne=(myid+1)*(npt+1)
      else
        ns=resid+myid*npt+1
        ne=resid+(myid+1)*npt
      end if
      
      end subroutine procdiv
