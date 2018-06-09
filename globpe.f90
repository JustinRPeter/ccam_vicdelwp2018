! Conformal Cubic Atmospheric Model
    
! Copyright 2015-2018 Commonwealth Scientific Industrial Research Organisation (CSIRO)
    
! This file is part of the Conformal Cubic Atmospheric Model (CCAM)
!
! CCAM is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! CCAM is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with CCAM.  If not, see <http://www.gnu.org/licenses/>.

!------------------------------------------------------------------------------

!      PE model on conformal-cubic grid
!cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
!      input files are :namelist (via file called "input")
!                       "nrun.dat"
!      data input and output file names are specified in namelist 'datafile'
!ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
!     sign convention:
!                      u+ve eastwards  (on the panel)
!                      v+ve northwards (on the panel)

program globpe

use aerointerface                          ! Aerosol interface
use aerosolldr, only : xtosav,xtg          ! LDR prognostic aerosols
use arrays_m                               ! Atmosphere dyamics prognostic arrays
use bigxy4_m                               ! Grid interpolation
use cc_mpi                                 ! CC MPI routines
use cc_omp                                 ! CC OpenMP routines
use cloudmod                               ! Prognostic cloud fraction
use const_phys                             ! Physical constants
use convjlm_m                              ! Convection
use convjlm22_m                            ! Convection v2
use dates_m                                ! Date data
use daviesnudge                            ! Far-field nudging
use diag_m                                 ! Diagnostic routines
use dpsdt_m                                ! Vertical velocity
use epst_m                                 ! Off-centre terms
use estab                                  ! Liquid saturation function
use extraout_m                             ! Additional diagnostics
use filnames_m                             ! Filenames
use gdrag_m, only : gwdrag                 ! Gravity wave drag
use histave_m                              ! Time average arrays
use hs_phys_m                              ! Held & Suarez
use indata                                 ! Data initialisation
use indices_m                              ! Grid index arrays
use infile                                 ! Input file routines
use kuocomb_m                              ! JLM convection
use leoncld_mod, only : leoncld            ! Prognostic cloud condensate
use liqwpar_m                              ! Cloud water mixing ratios
use map_m                                  ! Grid map arrays
use mlodynamics                            ! Ocean dynamics
use morepbl_m                              ! Additional boundary layer diagnostics
use nesting                                ! Nesting and assimilation
use newmpar_m                              ! Grid parameters
use nharrs_m, only : lrestart              ! Non-hydrostatic atmosphere arrays
use nlin_m                                 ! Atmosphere non-linear dynamics
use outcdf                                 ! Output file routines
use parm_m                                 ! Model configuration
use parmdyn_m                              ! Dynamics parameters
use parmhdff_m                             ! Horizontal diffusion parameters
use pbl_m                                  ! Boundary layer arrays
use prec_m                                 ! Precipitation
use raddiag_m                              ! Radiation diagnostic
use river                                  ! River routing
use savuvt_m                               ! Saved dynamic arrays
use savuv1_m                               ! Saved dynamic arrays
use sbar_m                                 ! Saved dynamic arrays
use screen_m                               ! Screen level diagnostics
use seaesfrad_m                            ! SEA-ESF radiation
use sflux_m                                ! Surface flux routines
use sigs_m                                 ! Atmosphere sigma levels
use soil_m                                 ! Soil and surface data
use timeseries, only : write_ts            ! Tracer time series
use tracermodule, only : tracer_mass     & ! Tracer routines
   ,interp_tracerflux
use tracers_m                              ! Tracer data
use uvbar_m                                ! Saved dynamic arrays
use vertmix_m                              ! Boundary layer turbulent mixing
use vvel_m                                 ! Additional vertical velocity
use work3f_m                               ! Grid work arrays
use xarrs_m                                ! Saved dynamic arrays
use xyzinfo_m                              ! Grid coordinate arrays

#ifdef csircoupled
use vcom_ccam                              ! CSIR (SA) ocean model
#endif

implicit none

include 'kuocom.h'                         ! Convection parameters
      
integer, dimension(8) :: tvals1, tvals2, nper3hr
integer, dimension(8) :: times_total_a, times_total_b
integer iq, isoil, i, j, k, nn, js, je, tile
integer mins_gmt, mspeca, mtimer_in
integer nlx, nmaxprsav, n3hr
integer nwtsav, mtimer_sav
integer jyear, jmonth, jday, jhour, jmin, mins
real, dimension(:), allocatable, save :: spare1
real, dimension(3) :: temparray, gtemparray
real aa, bb, cc 
real hourst, hrs_dt, evapavge, precavge
real pwatr, bb_2, cc_2, rat
logical oxidant_update
character(len=10) timeval

! Start model timer
call date_and_time(values=times_total_a)


! Compile options tests
#ifdef i8r8
if ( kind(iq)/=8 .or. kind(aa)/=8 ) then
  write(6,*) "ERROR: CCAM compiled for double precision, but single precision code was detected"
  stop
end if
#else
if ( kind(iq)/=4 .or. kind(aa)/=4 ) then
  write(6,*) "ERROR: CCAM compiled for single precision, but double precision code was detected"
  stop
end if
#endif


!--------------------------------------------------------------
! INITALISE MPI and OpenMP ROUTINES
call ccmpi_init
call ccomp_init

! Start banner
if ( myid==0 ) then
  write(6,*) "=============================================================================="
  write(6,*) "CCAM: Starting globpea"
  write(6,*) "=============================================================================="
end if

#ifndef stacklimit
! For Linux only - automatically removes stacklimit on all processes
call setstacklimit(-1)
#endif


!----------------------------------------------------------------
! INITALISE TIMING LOGS, READ NAMELIST AND INITIALISE MODEL
call log_off
call log_setup
call globpe_init


!****************************************************************
! only perform calculation on processes that are still active
if ( myid<nproc ) then
    
    
  !--------------------------------------------------------------
  ! OPEN OUTPUT FILES AND SAVE INITAL CONDITIONS
  if ( nwt>0 ) then
    ! write out the first ofile data set
    if ( myid==0 ) write(6,*) "calling outfile"
    call outfile(20)
    if ( newtop<0 ) then
      ! just for outcdf to plot zs  & write fort.22      
      if ( myid==0 ) write(6,*) "newtop<0 requires a stop here"
      call ccmpi_abort(-1)
    end if
  end if    ! (nwt>0)

  
  !-------------------------------------------------------------
  ! SETUP DIAGNOSTIC ARRAYS
  allocate( spare1(ifull) )
  do n3hr = 1,8
    nper3hr(n3hr) = nint(real(n3hr)*3.*3600./dt)
  end do
  n3hr = 1   ! initial value at start of run
  nlx = 0    ! diagnostic level
  call zero_nperavg
  call zero_nperday

  
  !--------------------------------------------------------------
  ! INITIALISE DYNAMICS
  dtin = dt
  if ( myid==0 ) then
    write(6,*) "number of time steps per day = ",nperday
    write(6,*) "nper3hr,nper6hr .. ",nper3hr(:)
  end if
  mspeca = 1
  ! use half time-step for initialisation
  if ( mex/=1 .and. .not.lrestart ) then
    mspeca = 2
    dt     = 0.5*dtin
  endif
  call gettin(0) ! preserve initial mass & T fields
  
  
  !--------------------------------------------------------------
  ! SET-UP TIMERS
  mtimer_sav = 0                                                       ! saved value for minute timer
  nmaxprsav  = nmaxpr
  nwtsav     = nwt
  hourst     = real(nint(0.01*real(ktime))) + real(mod(ktime,100))/60. ! for tracers
  mtimer_in  = mtimer

 
  !--------------------------------------------------------------
  ! BEGIN MAIN TIME LOOP
  if ( myid==0 ) then
    call date_and_time(time=timeval,values=tvals1)
    write(6,*) "Start of loop time ", timeval
  end if
  call log_on
  call START_LOG(maincalc_begin)

  do ktau = 1,ntau   ! ****** start of main time loop

    timer    = timer + real(ktau)*dtin/3600.             ! timer now only used to give timeg
    timeg    = mod( timer+hourst, 24. )                  ! UTC time for tracers
    mtimer   = mtimer_in + nint(real(ktau)*dtin/60.)     ! 15/6/01 to allow dt < 1 minute
    mins_gmt = mod( mtimer+60*ktime/100, 24*60 )         ! for radiation
    call getzinp(jyear,jmonth,jday,jhour,jmin,mins)      ! define mins as time since start of the year
    diag = ( ktau>=abs(ndi) .and. ktau<=ndi2 )           ! set diagnostic printout flag
    if ( ndi<0 ) then
      if ( ktau==(ktau/ndi)*ndi ) then
        diag = .true.
      end if
    endif

    ! interpolate tracer fluxes to current timestep
    if ( ngas>0 ) then
      call interp_tracerflux
    end if
    
    
    ! ***********************************************************************
    ! START ATMOSPHERE DYNAMICS
    ! ***********************************************************************
    
    ! NESTING ---------------------------------------------------------------
    if ( nbd/=0 ) then
      ! Newtonian relaxiation
      call START_LOG(nestin_begin)
      call nestin
      call END_LOG(nestin_end)
    end if
      
    
    ! DYNAMICS --------------------------------------------------------------
    call nantest("before atmosphere dynamics",1,ifull)   
    if ( nstaguin>0 .and. ktau>=1 ) then   ! swapping here for nstaguin>0
      if ( nstagin<0 .and. mod(ktau-nstagoff,abs(nstagin))==0 ) then
        nstag  = 7 - nstag  ! swap between 3 & 4
        nstagu = nstag
      endif
    endif

    do mspec = mspeca,1,-1    ! start of introductory time loop
   
      un(1:ifull,:) = 0. 
      vn(1:ifull,:) = 0.
      tn(1:ifull,:) = 0.

      if ( mup/=1 .or. (ktau==1.and.mspec==mspeca.and..not.lrestart) ) then
        call bounds(psl)
        ! updps called first step or to permit clean restart option      
        call updps(0) 
      endif
    
      if ( ktau<10 .and. nmaxpr==1 ) then
        if ( myid==0 ) then
          write(6,*) 'ktau,mex,mspec,mspeca:',ktau,mex,mspec,mspeca
        end if
      end if
    
      ! set up tau +.5 velocities in ubar, vbar
      sbar(:,2:kl) = sdot(:,2:kl)
      if ( (ktau==1.and..not.lrestart) .or. mex==1 ) then
        ubar(:,:) = u(1:ifull,:)
        vbar(:,:) = v(1:ifull,:)
      elseif ( (ktau==2.and..not.lrestart) .or. mex==2 ) then        
        ! (tau+.5) from tau, tau-1
        ubar(:,:) = u(1:ifull,:)*1.5 - savu(:,:)*.5
        vbar(:,:) = v(1:ifull,:)*1.5 - savv(:,:)*.5
      elseif ( mex==3 )then
        ! (tau+.5) from tau, tau-1, tau-2   ! ubar is savu1 here
        ubar(:,:) = u(1:ifull,:)+.5*(savu(:,:)-savu1(:,:))
        vbar(:,:) = v(1:ifull,:)+.5*(savv(:,:)-savv1(:,:))
      elseif ( mex==30 ) then  ! using tau, tau-1, tau-2, tau-3
        do k = 1,kl
          do iq = 1,ifull
            bb = 1.5*u(iq,k) - 2.*savu(iq,k) + .5*savu1(iq,k)                             ! simple b
            bb_2 = (40.*u(iq,k) - 35.*savu(iq,k) - 16.*savu1(iq,k) + 11.*savu2(iq,k))/34. ! cwqls b
            cc = .5*u(iq,k) - savu(iq,k) + .5*savu1(iq,k)                                 ! simple c
            cc_2 = (10.*u(iq,k) - 13.*savu(iq,k) - 4.*savu1(iq,k) + 7.*savu2(iq,k))/34.   ! cwqls c
            aa = cc_2 - cc
            rat = max( 0., min( 1., cc_2/(aa+sign(1.e-9,aa)) ) )
            cc = rat*cc + (1.-rat)*cc_2 
            bb = rat*bb + (1.-rat)*bb_2 
            ubar(iq,k) = u(iq,k) + .5*bb + .25*cc
            bb = 1.5*v(iq,k) - 2.*savv(iq,k) + .5*savv1(iq,k)                           ! simple b
            bb_2 = (40.*v(iq,k)-35.*savv(iq,k)-16.*savv1(iq,k)+11.*savv2(iq,k))/34.     ! cwqls b
            cc = .5*v(iq,k) - savv(iq,k) + .5*savv1(iq,k)                               ! simple c
            cc_2 = (10.*v(iq,k)-13.*savv(iq,k)-4.*savv1(iq,k)+7.*savv2(iq,k))/34.       ! cwqls c
            aa = cc_2 - cc
            rat = max( 0., min( 1., cc_2/(aa+sign(1.e-9,aa)) ) )
            cc = rat*cc + (1.-rat)*cc_2 
            bb = rat*bb + (1.-rat)*bb_2 
            vbar(iq,k) = v(iq,k)+.5*bb+.25*cc
          enddo ! iq loop
        enddo   ! k loop 
      else      ! i.e. mex >=4 and ktau>=3
        ! (tau+.5) from tau, tau-1, tau-2   ! ubar is savu1 here
        ubar(:,:) = (u(1:ifull,:)*15.-savu(:,:)*10.+savu1(:,:)*3.)/8.
        vbar(:,:) = (v(1:ifull,:)*15.-savv(:,:)*10.+savv1(:,:)*3.)/8.
      end if    ! (ktau==1) .. else ..
      
      if ( mod(ktau,nmaxpr)==0 .and. mydiag ) then
        nlx = max( 2, nlv )  ! as savs not defined for k=1
        write (6,"(i4,' savu2,savu1,savu,u,ubar',5f8.2)") ktau,savu2(idjd,nlv),savu1(idjd,nlv),savu(idjd,nlv), &
                                                          u(idjd,nlv),ubar(idjd,nlv)
        write (6,"(i4,' savv2,savv1,savv,v,vbar',5f8.2)") ktau,savv2(idjd,nlv),savv1(idjd,nlv),savv(idjd,nlv), &
                                                          v(idjd,nlv),vbar(idjd,nlv)
      end if
      if ( ktau>2 .and. epsp>1. .and. epsp<2. ) then
        if ( ktau==3 .and. nmaxpr==1 ) then
          if ( myid==0 ) then
            write(6,*) "using epsp= ",epsp
          end if
        end if
        where ( dpsdt(1:ifull)*dpsdtb(1:ifull)<0. .and. dpsdtbb(1:ifull)*dpsdtb(1:ifull)<0. )
          epst(1:ifull) = epsp - 1.
        elsewhere
          epst(1:ifull) = 0.
        end where
      endif ! (ktau>2.and.epsp>1..and.epsp<2.)

      if ( ktau<10 .and. mydiag ) then
        write(6,*)'savu,u,ubar ',ktau,savu(idjd,1),u(idjd,1),ubar(idjd,1)
      end if
      if ( ktau==1 .and. .not.lrestart .and. mspec==1 .and. mex/=1 ) then
        u(1:ifull,:) = savu(1:ifull,:)  ! reset u,v to original values
        v(1:ifull,:) = savv(1:ifull,:)
      end if
      savu2(1:ifull,:) = savu1(1:ifull,:)  
      savv2(1:ifull,:) = savv1(1:ifull,:)
      savs1(1:ifull,:) = savs(1:ifull,:)  
      savu1(1:ifull,:) = savu(1:ifull,:)  
      savv1(1:ifull,:) = savv(1:ifull,:)
      savs(1:ifull,:)  = sdot(1:ifull,2:kl)  
      savu(1:ifull,:)  = u(1:ifull,:)  ! before any time-splitting occurs
      savv(1:ifull,:)  = v(1:ifull,:)

      ! update non-linear dynamic terms
      call nonlin
      
      if ( diag ) then
        if ( mydiag ) write(6,*) 'before hadv'
        call printa('tx  ',tx,ktau,nlv,ia,ib,ja,jb,0.,1.)
        if ( mydiag ) then
          nlx = min( nlv, kl-8 )
          write(6,"('tx  ',9f8.2)") (tx(idjd,k),k=nlx,nlx+8)
          write(6,"('txe ',9f8.2)") (tx(ie(idjd),k),k=nlx,nlx+8)
          write(6,"('txw ',9f8.2)") (tx(iw(idjd),k),k=nlx,nlx+8)
          write(6,"('txn ',9f8.2)") (tx(in(idjd),k),k=nlx,nlx+8)
          write(6,"('txs ',9f8.2)") (tx(is(idjd),k),k=nlx,nlx+8)
          write(6,'(i2," qgv ",18f7.4)')ktau,(1000.*qg(idjd,k),k=1,kl)
        end if
        call printa('qgv ',qg,ktau,nlv,ia,ib,ja,jb,0.,1.e3)
      endif

      ! evaluate horizontal advection for combined quantities
      call upglobal
      
      if ( diag ) then
        if ( mydiag ) then
          write(6,*) 'after hadv'
          write (6,"('tx  ',9f8.2)") (tx(idjd,k),k=nlx,nlx+8)
        end if
        call printa('tx  ',tx,ktau,nlv,ia,ib,ja,jb,200.,1.)
        if ( mydiag ) then
          write(6,'(i2," qgh ",18f7.4)')ktau,1000.*qg(idjd,:)
        end if  
      end if

      if ( nstaguin<0 .and. ktau>=1 ) then  ! swapping here (lower down) for nstaguin<0
        if ( nstagin<0 .and. mod(ktau-nstagoff,abs(nstagin))==0 ) then
          nstag  = 7 - nstag  ! swap between 3 & 4
          nstagu = nstag
        end if
      end if
      
      ! Update the semi-implicit solution to the augumented geopotential
      call adjust5

      ! check for rounding errors
      call fixqg(1,ifull)
  
      call nantest("after atmosphere dynamics",1,ifull)

      
      ! NESTING ---------------------------------------------------------------
      ! nesting now after mass fixers
      if ( mspec==1 ) then
        if ( mbd/=0 .or. (mbd_mlo/=0.and.namip==0) ) then
          ! scale-selective filter
          call START_LOG(nestin_begin)
          call nestinb
          call nantest("after nesting",1,ifull)      
          call END_LOG(nestin_end)
        else if ( nbd/=0 ) then
          ! Newtonian relaxiation
          call START_LOG(nestin_begin)
          call davies
          call nantest("after nesting",1,ifull)      
          call END_LOG(nestin_end)
        end if
      end if
    
      
      ! DYNAMICS --------------------------------------------------------------
      if ( mspec==2 ) then     ! for very first step restore mass & T fields
        call gettin(1)
      endif    !  (mspec==2) 
      dt = dtin
      
    end do ! ****** end of introductory time loop

    mspeca = 1
  
    
    ! HORIZONTAL DIFFUSION ----------------------------------------------------
    if ( nhor<0 ) then
      call START_LOG(hordifg_begin)  
      call hordifgt
      if ( diag .and. mydiag ) then
        write(6,*) 'after hordifgt t ',t(idjd,:)
      end if
      call nantest("after atm horizontal diffusion",1,ifull)    
      call END_LOG(hordifg_end)
    end if  

    
    ! ***********************************************************************
    ! START RIVER ROUTING
    ! ***********************************************************************
    
    if ( abs(nriver)==1 ) then  
      call START_LOG(river_begin)
      call rvrrouter
      call END_LOG(river_end)
    end if

    
    ! ***********************************************************************
    ! START OCEAN DYNAMICS
    ! ***********************************************************************

    ! nmlo=0   Prescriped SSTs and sea-ice with JLM skin enhancement
    ! nmlo=1   1D mixed-layer-ocean model
    ! nmlo=2   nmlo=1 plus river-routing and horiontal diffusion
    ! nmlo=3   nmlo=2 plus 3D dynamics
    ! nmlo>9   Use external PCOM ocean model
  
    if ( abs(nmlo)>=3 .and. abs(nmlo)<=9 ) then
      ! DYNAMICS & DIFFUSION ------------------------------------------------
      call START_LOG(waterdynamics_begin)
      call mlohadv
      call END_LOG(waterdynamics_end)
    else if ( abs(nmlo)==2 ) then
      ! DIFFUSION ONLY ------------------------------------------------------
      call START_LOG(waterdynamics_begin)
      call mlodiffusion
      call END_LOG(waterdynamics_end)
    end if
      
      
#ifdef csircoupled
    ! ***********************************************************************
    ! VCOM ADVECTION
    ! ***********************************************************************
    call vcom_ccam_advect(fracice,sicedep,tss,tgg(:,1),tggsn(:,1))
#endif
      

    ! ***********************************************************************
    ! START PHYSICS 
    ! ***********************************************************************
    call START_LOG(phys_begin)

    
    ! MISC (SINGLE) ---------------------------------------------------------
    ! radiation timer calculations
    if ( nrad==5 ) then
      if ( nhstest<0 ) then      ! aquaplanet test -1 to -8  
        mtimer_sav = mtimer
        mtimer     = mins_gmt    ! so radn scheme repeatedly works thru same day
        call seaesfrad_settime
        mtimer = mtimer_sav
      else
        call seaesfrad_settime  
      end if    ! (nhstest<0)      
    end if    
    ! aerosol timer calculations
    oxidant_update = oxidant_timer<=mins-updateoxidant

    
    ! MISC (PARALLEL) -------------------------------------------------------
!$omp parallel
!$omp do schedule(static) private(js,je)
    do tile = 1,ntiles
      js = (tile-1)*imax + 1
      je = tile*imax  
      ! initialse surface rainfall to zero
      condc(js:je) = 0. ! default convective rainfall (assumed to be rain)
      condx(js:je) = 0. ! default total precip = rain + ice + snow + graupel (convection and large scale)
      conds(js:je) = 0. ! default total ice + snow (convection and large scale)
      condg(js:je) = 0. ! default total graupel (convection and large scale)
      ! Held & Suarez or no surf fluxes
      if ( ntsur<=1 .or. nhstest==2 ) then 
        eg(js:je)   = 0.
        fg(js:je)   = 0.
        cdtq(js:je) = 0.
        cduv(js:je) = 0.
      end if     ! (ntsur<=1.or.nhstest==2) 
      ! Save aerosol concentrations for outside convective fraction of grid box
      if ( abs(iaero)>=2 ) then
        xtosav(js:je,:,:) = xtg(js:je,:,:) ! Aerosol mixing ratio outside convective cloud
      end if
      js = (tile-1)*imax + 1
      je = tile*imax  
      call nantest("start of physics",js,je)
    end do  
!$omp end do nowait
    
    
    ! GWDRAG ----------------------------------------------------------------
!$omp master
    call START_LOG(gwdrag_begin)
!$omp end master
    if ( ngwd<0 ) then
      call gwdrag  ! <0 for split - only one now allowed
    end if
!$omp do schedule(static) private(js,je)
    do tile = 1,ntiles
      js = (tile-1)*imax + 1
      je = tile*imax  
      call nantest("after gravity wave drag",js,je)
    end do  
!$omp end do nowait
!$omp master
    call END_LOG(gwdrag_end)
!$omp end master

  
    ! CONVECTION ------------------------------------------------------------
!$omp master
    call START_LOG(convection_begin)
!$omp end master
!$omp do schedule(static) private(js,je)
    do tile = 1,ntiles
      js = (tile-1)*imax + 1
      je = tile*imax  
      convh_ave(js:je,1:kl) = convh_ave(js:je,1:kl) - t(js:je,1:kl)*real(nperday)/real(nperavg)        
    end do
!$omp end do nowait
    ! Select convection scheme
    select case ( nkuo )
      case(5)
!$omp barrier  
!$omp single  
        call betts(t,qg,tn,land,ps) ! not called these days
!$omp end single
      case(21,22)
        call convjlm22              ! split convjlm 
      case(23,24)
        call convjlm                ! split convjlm 
    end select
!$omp do schedule(static) private(js,je)
    do tile = 1,ntiles
      js = (tile-1)*imax + 1
      je = tile*imax  
      call fixqg(js,je)
      call nantest("after convection",js,je)
    end do  
!$omp end do nowait
!$omp master
    call END_LOG(convection_end)
!$omp end master

    
    ! CLOUD MICROPHYSICS ----------------------------------------------------
!$omp master
    call START_LOG(cloud_begin)
!$omp end master
    if ( ldr/=0 ) then
      ! LDR microphysics scheme
      call leoncld
    end if
!$omp do schedule(static) private(js,je)
    do tile = 1,ntiles
      js = (tile-1)*imax + 1
      je = tile*imax  
      convh_ave(js:je,1:kl) = convh_ave(js:je,1:kl) + t(js:je,1:kl)*real(nperday)/real(nperavg)    
      call nantest("after cloud microphysics",js,je) 
    end do  
!$omp end do nowait
!$omp master    
    call END_LOG(cloud_end)
!$omp end master
    
    
    ! RADIATION -------------------------------------------------------------
!$omp master
    call START_LOG(radnet_begin)
!$omp end master
    if ( ncloud>=4 ) then
!$omp do schedule(static) private(js,je)
      do tile = 1,ntiles
        js = (tile-1)*imax + 1
        je = tile*imax 
        nettend(js:je,1:kl) = nettend(js:je,1:kl) + t(js:je,1:kl)/dt
      end do
!$omp end do nowait
    end if
    select case ( nrad )
      case(4)
!$omp barrier  
!$omp single  
        ! Fels-Schwarzkopf radiation
        if ( nhstest<0 ) then ! aquaplanet test -1 to -8  
          mtimer_sav = mtimer
          mtimer     = mins_gmt    ! so radn scheme repeatedly works thru same day
          call radrive(il*nrows_rad)
          mtimer = mtimer_sav
        else
          call radrive(il*nrows_rad)  
          do k = 1,kl
            t(1:ifull,k) = t(1:ifull,k) - dt*(sw_tend(1:ifull,k)+lw_tend(1:ifull,k))
          end do
        end if    ! (nhstest<0)
!$omp end single
      case(5)
        ! GFDL SEA-EFS radiation
        call seaesfrad
!$omp do schedule(static) private(js,je,k)
        do tile = 1,ntiles
          js = (tile-1)*imax + 1
          je = tile*imax 
          do k = 1,kl
            t(js:je,k) = t(js:je,k) - dt*(sw_tend(js:je,k)+lw_tend(js:je,k))
          end do
        end do  
!$omp end do nowait
      case DEFAULT
        ! use preset slwa array (use +ve nrad)
!$omp do schedule(static) private(js,je)
        do tile = 1,ntiles
          js = (tile-1)*imax + 1
          je = tile*imax 
          slwa(js:je) = -real(10*nrad)
        end do  
!$omp end do nowait
    end select
!$omp do schedule(static) private(js,je)  
    do tile = 1,ntiles
      js = (tile-1)*imax + 1
      je = tile*imax 
      call nantest("after radiation",js,je)    
    end do  
!$omp end do nowait
!$omp master
    call END_LOG(radnet_end)
!$omp end master

    
    ! HELD & SUAREZ ---------------------------------------------------------
    if ( nhstest==2 ) then
      call hs_phys
    end if

    
    ! SURFACE FLUXES ---------------------------------------------
    ! (Includes ocean dynamics and mixing, as well as ice dynamics and thermodynamics)
!$omp master
    call START_LOG(sfluxnet_begin)
!$omp end master
    if ( diag .and. ntiles==1 ) then
      call maxmin(u,'#u',ktau,1.,kl)
      call maxmin(v,'#v',ktau,1.,kl)
      call maxmin(t,'#t',ktau,1.,kl)
      call maxmin(qg,'qg',ktau,1.e3,kl)     
    end if
    if ( ntsur>1 ) then
      call sflux
    endif   ! (ntsur>1)    
!$omp do schedule(static) private(js,je)  
    do tile = 1,ntiles
      js = (tile-1)*imax + 1
      je = tile*imax 
      call nantest("after surface fluxes",js,je)
    end do  
!$omp end do nowait
!$omp master
    call END_LOG(sfluxnet_end)
!$omp end master


    ! AEROSOLS --------------------------------------------------------------
    ! MJT notes - aerosols called before vertical mixing so that convective
    ! and strat cloud can be separated in a way that is consistent with
    ! cloud microphysics
!$omp master
    call START_LOG(aerosol_begin)
!$omp end master
    if ( abs(iaero)>=2 ) then
      call aerocalc(oxidant_update,mins)
    end if
!$omp do schedule(static) private(js,je)
    do tile = 1,ntiles
      js = (tile-1)*imax + 1
      je = tile*imax  
      call nantest("after aerosols",js,je)
    end do  
!$omp end do nowait
!$omp master
    call END_LOG(aerosol_end)
!$omp end master
    
    
    ! VERTICAL MIXING ------------------------------------------------------
!$omp master
    call START_LOG(vertmix_begin)
    if ( nmaxpr==1 ) then
      if ( mydiag .and. ntiles==1 ) then
        write (6,"('pre-vertmix t',9f8.3/13x,9f8.3)") t(idjd,:)
      end if
    end if
!$omp end master
    if ( ntsur>=1 ) then
      call vertmix
    endif  ! (ntsur>=1)
!$omp do schedule(static) private(js,je)
    do tile = 1,ntiles
      js = (tile-1)*imax + 1
      je = tile*imax  
      call fixqg(js,je)
      call nantest("after PBL mixing",js,je)
    end do  
!$omp end do nowait
!$omp master
    if ( nmaxpr==1 ) then
      if ( mydiag .and. ntiles==1 ) then
        write (6,"('aft-vertmix t',9f8.3/13x,9f8.3)") t(idjd,:)
      end if
    end if
    call END_LOG(vertmix_end)
!$omp end master

    
    ! MISC (PARALLEL) -------------------------------------------------------
    ! Update diagnostics for consistancy in history file
    if ( rescrn>0 ) then
!$omp do schedule(static) private(js,je)
      do tile = 1,ntiles
        js = (tile-1)*imax + 1
        je = tile*imax  
        call autoscrn(js,je)
      end do
!$omp end do nowait
    end if
!$omp do schedule(static) private(js,je)
    do tile = 1,ntiles
      js = (tile-1)*imax + 1
      je = tile*imax  
      ! Convection diagnostic output
      cbas_ave(js:je) = cbas_ave(js:je) + condc(js:je)*(1.1-sig(kbsav(js:je)))      ! diagnostic
      ctop_ave(js:je) = ctop_ave(js:je) + condc(js:je)*(1.1-sig(abs(ktsav(js:je)))) ! diagnostic
      ! Microphysics diagnostic output
      do k = 1,kl
        riwp_ave(js:je) = riwp_ave(js:je) - qfrad(js:je,k)*dsig(k)*ps(js:je)/grav ! ice water path
        rlwp_ave(js:je) = rlwp_ave(js:je) - qlrad(js:je,k)*dsig(k)*ps(js:je)/grav ! liq water path
      end do
      rnd_3hr(js:je,8) = rnd_3hr(js:je,8) + condx(js:je)  ! i.e. rnd24(:)=rnd24(:)+condx(:)
    end do  
!$omp end do nowait

!$omp end parallel


    ! MISC (SINGLE) ---------------------------------------------------------
    ! Update aerosol timer
    if ( oxidant_update ) then
      oxidant_timer = mins
    end if

    call END_LOG(phys_end)

    
#ifdef csircoupled
    ! ***********************************************************************
    ! VCOM DIFFUSION
    ! ***********************************************************************
    call vcom_ccam_diffusion(fracice,sicedep,tss,tgg(:,1),tggsn(:,1))
#endif

  
    ! ***********************************************************************
    ! DIAGNOSTICS AND OUTPUT
    ! ***********************************************************************

    ! TIME AVERAGED OUTPUT ---------------------------------------
    ! update diag_averages and daily max and min screen temps 
    ! N.B. runoff is accumulated in sflux
    call calculate_timeaverage


    ! TRACER OUTPUT ----------------------------------------------
    if ( ngas>0 ) then
      call tracer_mass !also updates average tracer array
      call write_ts(ktau,ntau,dt)
    endif

    
    ! STATION OUTPUT ---------------------------------------------
    if ( nstn>0 ) then
      call stationa ! write every time step
    end if
    
    
    ! DIAGNOSTICS ------------------------------------------------
    call write_diagnostics(mins_gmt,nmaxprsav)
    
    if ( myid==0 ) then
      write(6,*) 'ktau,mod,nper3hr ',ktau,mod(ktau-1,nperday)+1,nper3hr(n3hr)
    end if

    ! rnd03 to rnd21 are accumulated in mm     
    if ( mod(ktau-1,nperday)+1 == nper3hr(n3hr) ) then
      rnd_3hr(1:ifull,n3hr) = rnd_3hr(1:ifull,8)
      if ( nextout>=2 ) then
        spare1(:) = max( .001, sqrt(u(1:ifull,1)**2+v(1:ifull,1)**2) )
        u10_3hr(:,n3hr) = u10(:)*u(1:ifull,1)/spare1(:)
        v10_3hr(:,n3hr) = u10(:)*v(1:ifull,1)/spare1(:)
        tscr_3hr(:,n3hr) = tscrn(:)
        spare1(:) = establ(t(1:ifull,1)) ! spare1 = es
        rh1_3hr(1:ifull,n3hr) = 100.*qg(1:ifull,1)*(ps(1:ifull)*sig(1)-spare1(:))/(.622*spare1(:))
      end if    ! (nextout==2)
      n3hr = n3hr + 1
      if ( n3hr>8 ) n3hr = 1
    endif    ! (mod(ktau,nperday)==nper3hr(n3hr))
  

    ! WRITE DATA TO HISTORY AND RESTART FILES --------------------
    call log_off
    if ( ktau==ntau .or. mod(ktau,nwt)==0 ) then
      call outfile(20)  ! which calls outcdf
      if ( ktau==ntau .and. irest==1 ) then
        ! Don't include the time for writing the restart file
        call END_LOG(maincalc_end)
        ! write restart file
        call outfile(19)
        if ( myid==0 ) write(6,*) 'finished writing restart file in outfile'
        call START_LOG(maincalc_begin)
      endif  ! (ktau==ntau.and.irest==1)
    endif    ! (ktau==ntau.or.mod(ktau,nwt)==0)
    ! write high temporal frequency fields
    if ( surfile /= ' ' ) then
      call freqfile
    end if
    call log_on
 
    
    ! TIME AVERAGED DIAGNOSTICS ---------------------------------
    if ( mod(ktau,nperavg)==0 ) then  
        
      ! produce some diags & reset most averages once every nperavg
      if ( nmaxpr==1 ) then
        precavge = sum(precip(1:ifull)*wts(1:ifull))
        evapavge = sum(evap(1:ifull)*wts(1:ifull))   ! in mm/day
        pwatr    = 0.   ! in mm
        do k = 1,kl
          pwatr = pwatr - sum(dsig(k)*wts(1:ifull)*(qg(1:ifull,k)+qlg(1:ifull,k)+qfg(1:ifull,k))*ps(1:ifull))/grav
        enddo
        temparray(1:3) = (/ precavge, evapavge, pwatr /)
        call ccmpi_reduce(temparray(1:3),gtemparray(1:3),"max",0,comm_world)
        if ( myid==0 ) then
          precavge = gtemparray(1)
          evapavge = gtemparray(2)
          pwatr    = gtemparray(3)
          write(6,985) pwatr,precavge,evapavge ! MJT bug fix
985       format(' average pwatr,precc,prec,evap: ',4f7.3)
        end if
      end if
      ! also zero most averaged fields every nperavg
      call zero_nperavg
      
    endif  ! (mod(ktau,nperavg)==0)

    ! DAILY DIAGNOSTICS ----------------------------------------
    if ( mod(ktau,nperday)==0 ) then   ! re-set at the end of each 24 hours
        
      if ( ntau<10*nperday .and. nstn>0 ) then     ! print stn info
        do nn = 1,nstn
          if ( mystn(nn) ) then
            i = istn(nn)
            j = jstn(nn)
            iq = i+(j-1)*il
            write(6,956) ktau,iunp(nn),name_stn(nn),rnd_3hr(iq,4),rnd_3hr(iq,8), &
                         tmaxscr(iq)-273.16+(zs(iq)/grav-zstn(nn))*stdlapse,     &
                         tminscr(iq)-273.16+(zs(iq)/grav-zstn(nn))*stdlapse,     &
                         tmaxscr(iq)-273.16,tminscr(iq)-273.16
956         format(i5,i3,a5,6f7.1)
          end if               
        end do
      end if  ! (ntau<10*nperday)
      call zero_nperday
      
    endif   ! (mod(ktau,nperday)==0)
  
    
    ! AMIP SSTs --------------------------------------------------
    if ( namip/=0 ) then
      call START_LOG(amipsst_begin)
      if ( nmlo==0 ) then
        ! call once per day for prescribed SSTs  
        if ( mod(ktau,nperday)==0 ) then
          if ( myid==0 ) write(6,*) "amipsst called at end of day for ktau,mtimer,namip ",ktau,mtimer,namip  
          call amipsst
        end if
      else
        ! call every time-step for nudging prognostic SSTs
        call amipsst
      end if
      call END_LOG(amipsst_end)
    end if

    
    ! Flush trace information to disk to save memory.
    call log_flush()

    
  end do                  ! *** end of main time loop
  
  call END_LOG(maincalc_end)
  call log_off
  
  
  !------------------------------------------------------------------
  ! SIMULATION COMPLETE
  
  ! Report timings of run
  if ( myid==0 ) then
    call date_and_time(time=timeval,values=tvals2)
    write(6,*) "End of time loop ", timeval
    write(6,*) "normal termination of run"
    write(6,*) "End time ", timeval
    aa = sum( real(tvals2(5:8)-tvals1(5:8))*(/ 3600., 60., 1., 0.001 /) )
    if ( aa<0. ) aa = aa + 86400.
    write(6,*) "Model time in main loop",aa
  end if
  
  ! close mesonest files
  if ( mbd/=0 .or. nbd/=0 ) then
    call histclose
  end if

#ifdef csircoupled
  ! finalize VCOM
  call vcom_finialize
#endif
  
  call date_and_time(values=times_total_b)
  total_time = sum( real(times_total_b(5:8)-times_total_a(5:8))*(/ 3600., 60., 1., 0.001 /) )
  if ( total_time<0 ) total_time = total_time + 86400.
  
#ifdef simple_timer
  ! report subroutine timings
  call simple_timer_finalize
#endif

  ! Complete
  if ( myid==0 ) then
    write(6,*) "------------------------------------------------------------------------------"
    write(6,*) "CCAM: globpea completed successfully"
    call finishbanner
  end if

#ifdef usempi3
  call ccmpi_freeshdata(xx4_win)
  call ccmpi_freeshdata(yy4_win)
  call ccmpi_freeshdata(em_g_win)
  call ccmpi_freeshdata(x_g_win)
  call ccmpi_freeshdata(y_g_win)
  call ccmpi_freeshdata(z_g_win)
#else
  deallocate(xx4_dummy,yy4_dummy)
  deallocate(em_g_dummy)
  deallocate(x_g_dummy,y_g_dummy,z_g_dummy)
#endif
  
end if ! myid<nproc
!****************************************************************

! finalize MPI comms
call ccmpi_finalize

end

    
!--------------------------------------------------------------
! END OF CCAM LOG    
subroutine finishbanner

implicit none

! End banner
write(6,*) "=============================================================================="
write(6,*) "CCAM: Finished globpea"
write(6,*) "=============================================================================="

return
end
    

!--------------------------------------------------------------
! PREPARE SPECIAL TRACER ARRAYS
! sets tr arrays for lat, long, pressure if nextout>=4 &(nllp>=3)
subroutine setllp
      
use arrays_m           ! Atmosphere dyamics prognostic arrays
use cc_mpi             ! CC MPI routines
use const_phys         ! Physical constants
use latlong_m          ! Lat/lon coordinates
use newmpar_m          ! Grid parameters
use sigs_m             ! Atmosphere sigma levels
use tracers_m          ! Tracer data
      
implicit none
      
integer k
      
if ( nllp<3 ) then
  write(6,*) "ERROR: Incorrect setting of nllp",nllp
  call ccmpi_abort(-1)
end if
      
do k = 1,kl
  tr(1:ifull,k,ngas+1) = rlatt(1:ifull)*180./pi
  tr(1:ifull,k,ngas+2) = rlongg(1:ifull)*180./pi
  tr(1:ifull,k,ngas+3) = .01*ps(1:ifull)*sig(k)  ! in HPa
enddo
if ( nllp >= 4 ) then   ! theta
  do k = 1,kl
    tr(1:ifull,k,ngas+4) = t(1:ifull,k)*(1.e-5*ps(1:ifull)*sig(k))**(-rdry/cp)
  enddo
endif   ! (nllp>=4)
if ( nllp >= 5 ) then   ! mixing_ratio (g/kg)
  do k = 1,kl
    tr(1:ifull,k,ngas+5) = 1000.*qg(1:ifull,k)
  enddo
endif   ! (nllp>=5)
      
return
end subroutine setllp


!--------------------------------------------------------------
! INTIAL PARAMETERS
blockdata main_blockdata

implicit none

include 'kuocom.h'           ! Convection parameters

! Vertical mixing options
data ncvmix/0/
! Cumulus convection options
data nkuo/23/,sigcb/1./,sig_ct/1./,rhcv/0./,rhmois/.1/,rhsat/1./
data convfact/1.02/,convtime/.33/,shaltime/0./
data alflnd/1.1/,alfsea/1.1/,fldown/.6/,iterconv/3/,ncvcloud/0/
data nevapcc/0/,nevapls/-4/,nuvconv/0/
data mbase/101/,mdelay/-1/,methprec/8/,nbase/-4/,detrain/.15/
data entrain/.05/,methdetr/2/,detrainx/0./,dsig2/.15/,dsig4/.4/
! Shallow convection options
data ksc/-95/,kscsea/0/,kscmom/1/,sigkscb/.95/,sigksct/.8/
data tied_con/2./,tied_over/0./,tied_rh/.75/
! Other moist physics options
data acon/.2/,bcon/.07/,rcm/.92e-5/
data rcrit_l/.75/,rcrit_s/.85/ 
! Cloud options
data ldr/1/,nclddia/1/,nstab_cld/0/,nrhcrit/10/,sigcll/.95/ 
data cldh_lnd/95./,cldm_lnd/85./,cldl_lnd/75./
data cldh_sea/95./,cldm_sea/90./,cldl_sea/80./
data ncloud/0/

end
      
!--------------------------------------------------------------
! WRITE STATION DATA
subroutine stationa

use arrays_m           ! Atmosphere dyamics prognostic arrays
use cc_mpi             ! CC MPI routines
use const_phys         ! Physical constants
use dates_m            ! Date data
use diag_m             ! Diagnostic routines
use estab              ! Liquid saturation function
use extraout_m         ! Additional diagnostics
use indata             ! Data initialisation
use map_m              ! Grid map arrays
use morepbl_m          ! Additional boundary layer diagnostics
use newmpar_m          ! Grid parameters
use nsibd_m            ! Land-surface arrays
use parm_m             ! Model configuration
use parmgeom_m         ! Coordinate data
use pbl_m              ! Boundary layer arrays
use prec_m             ! Precipitation
use screen_m           ! Screen level diagnostics
use sigs_m             ! Atmosphere sigma levels
use soil_m             ! Soil and surface data
use soilsnow_m         ! Soil, snow and surface data
use soilv_m            ! Soil parameters
use tracers_m          ! Tracer data
use vecsuv_m           ! Map to cartesian coordinates
use vegpar_m           ! Vegetation arrays
use work2_m            ! Diagnostic arrays
use work3_m            ! Mk3 land-surface diagnostic arrays
use xyzinfo_m          ! Grid coordinate arrays

implicit none

integer i, j, iq, iqt, isoil, k2, nn
real coslong, sinlong, coslat, sinlat, polenx, poleny, polenz
real zonx, zony, zonz, den, costh, sinth, uzon, vmer, rh1, rh2
real es, wbav, rh_s

coslong = cos(rlong0*pi/180.)   ! done here, where work2 has arrays
sinlong = sin(rlong0*pi/180.)
coslat  = cos(rlat0*pi/180.)
sinlat  = sin(rlat0*pi/180.)
polenx  = -coslat
poleny  = 0.
polenz  = sinlat
do nn = 1,nstn
  ! Check if this station is in this processors region
  if ( .not. mystn(nn) ) cycle 
  if ( ktau == 1 ) then
    write (iunp(nn),950) kdate,ktime,leap
  end if
950 format("#",i9,2i5)
  i = istn(nn)
  j = jstn(nn)
  iq = i + (j-1)*il
  zonx  = real(            -polenz*y(iq))
  zony  = real(polenz*x(iq)-polenx*z(iq))
  zonz  = real(polenx*y(iq)             )
  den   = sqrt( max(zonx**2+zony**2+zonz**2,1.e-7) ) 
  costh =  (zonx*ax(iq)+zony*ay(iq)+zonz*az(iq))/den
  sinth = -(zonx*bx(iq)+zony*by(iq)+zonz*bz(iq))/den
  uzon  = costh*u(iq,1)-sinth*v(iq,1)
  vmer  = sinth*u(iq,1)+costh*v(iq,1)
  es   = establ(t(iq,1))
  rh1  = 100.*qg(iq,1)*(ps(iq)*sig(1)-es)/(.622*es)
  es   = establ(t(iq,2))
  rh2  = 100.*qg(iq,2)*(ps(iq)*sig(2)-es)/(.622*es)
  es   = establ(tscrn(iq))
  rh_s = 100.*qgscrn(iq)*(ps(iq)-es)/(.622*es)
  wbav = (zse(1)*wb(iq,1)+zse(2)*wb(iq,2)+zse(3)*wb(iq,3)+zse(4)*wb(iq,4))/(zse(1)+zse(2)+zse(3)+zse(4))
  iqt = min( iq, il*jl ) ! Avoid bounds problems if there are no tracers
  k2  = min( 2, kl )
  write (iunp(nn),951) ktau,tscrn(iq)-273.16,rnd_3hr(iq,8),      &
        tss(iq)-273.16,tgg(iq,1)-273.16,tgg(iq,2)-273.16,        &
        tgg(iq,3)-273.16,t(iq,1)-273.16,0.,wb(iq,1),wb(iq,2),    &
        cloudlo(iq),cloudmi(iq)+1.,cloudhi(iq)+2.,               &
        cloudtot(iq)+3.,fg(iq),eg(iq),0.,0.,rnet(iq),sgsave(iq), &
        qg(iq,1)*1.e3,uzon,vmer,precc(iq),qg(iq,2)*1.e3,rh1,rh2, &
        0.,0.,0.,0.,.01*ps(iq),wbav,epot(iq),qgscrn(iq)*1.e3,    &
        rh_s,u10(iq),uscrn(iq),condx(iq)
  ! N.B. qgscrn formula needs to be greatly improved
951 format(i4,6f7.2,                                             &
           2f7.2, 2f6.3, 4f5.2,                                  & ! t1 ... cld
           5f7.1,f6.1,f5.1,                                      & ! fg ... qg1
           2f6.1,f7.2, f5.1,2f6.1, 2(1x,f5.1),                   & ! uu ... co2_2
           2(1x,f5.1) ,f7.1,f6.3,f7.1,5f6.1,                     & ! rad_1 ... rh_s
           f7.2)                                                   ! condx
  if ( ktau == ntau ) then
    write (iunp(nn),952)
952 format("#   2tscrn 3precip 4tss  5tgg1  6tgg2  7tgg3",               &
           "   8t1    9tgf  10wb1 11wb2 cldl cldm cldh  cld",            &
           "   16fg   17eg  18fgg  19egg  20rnet 21sg 22qg1",            &
           " 23uu   24vv 25precc qg2  rh1 28rh2 29co2_1 co2_2",          &
           " rad_1 rad_2  ps 34wbav 35epot qgscrn 37rh_s 38u10 uscrn",   &
           " 40condx")
    write (iunp(nn),953) land(iq),isoilm(iq),ivegt(iq),zo(iq),zs(iq)/grav
953 format("# land,isoilm,ivegt,zo,zs/g: ",l2,2i3,2f9.3)
    isoil = max(1,isoilm(iq))
    write (iunp(nn),954) sigmf(iq),swilt(isoil),sfc(isoil),ssat(isoil),0.5*sum(albvisnir(iq,:))
954 format("#sigmf,swilt,sfc,ssat,alb: ",5f7.3)
  end if
end do
return
end subroutine stationa

    
!--------------------------------------------------------------
! INITIALISE CCAM
subroutine globpe_init

use aerosolldr, only : naero,ch_dust     & ! LDR prognostic aerosols
    ,zvolcemi,aeroindir,so4mtn,carbmtn   &
    ,saltsmallmtn,saltlargemtn
use arrays_m                               ! Atmosphere dyamics prognostic arrays
use ateb, only : atebnmlfile             & ! Urban
    ,ateb_energytol=>energytol           &
    ,ateb_resmeth=>resmeth               &
    ,ateb_useonewall=>useonewall         &
    ,ateb_zohmeth=>zohmeth               &
    ,ateb_acmeth=>acmeth                 &
    ,ateb_nrefl=>nrefl                   &
    ,ateb_vegmode=>vegmode               &
    ,ateb_soilunder=>soilunder           &
    ,ateb_conductmeth=>conductmeth       &
    ,ateb_scrnmeth=>scrnmeth             &
    ,ateb_wbrelaxc=>wbrelaxc             &
    ,ateb_wbrelaxr=>wbrelaxr             &
    ,ateb_lweff=>lweff                   &
    ,ateb_ncyits=>ncyits                 &
    ,ateb_nfgits=>nfgits                 &
    ,ateb_tol=>tol                       &
    ,ateb_alpha=>alpha                   &
    ,ateb_zosnow=>zosnow                 &
    ,ateb_snowemiss=>snowemiss           &
    ,ateb_maxsnowalpha=>maxsnowalpha     &
    ,ateb_minsnowalpha=>minsnowalpha     &
    ,ateb_maxsnowden=>maxsnowden         &
    ,ateb_minsnowden=>minsnowden         &
    ,ateb_refheight=>refheight           &
    ,ateb_zomratio=>zomratio             &
    ,ateb_zocanyon=>zocanyon             &
    ,ateb_zoroof=>zoroof                 &
    ,ateb_maxrfwater=>maxrfwater         &
    ,ateb_maxrdwater=>maxrdwater         &
    ,ateb_maxrfsn=>maxrfsn               &
    ,ateb_maxrdsn=>maxrdsn               &
    ,ateb_maxvwatf=>maxvwatf             &
    ,ateb_intairtmeth=>intairtmeth       &
    ,ateb_intmassmeth=>intmassmeth       &
    ,ateb_cvcoeffmeth=>cvcoeffmeth       &
    ,ateb_statsmeth=>statsmeth           &
    ,ateb_behavmeth=>behavmeth           &
    ,ateb_infilmeth=>infilmeth           &
    ,ateb_ac_heatcap=>ac_heatcap         &
    ,ateb_ac_coolcap=>ac_coolcap         &
    ,ateb_ac_heatprop=>ac_heatprop       &
    ,ateb_ac_coolprop=>ac_coolprop       &
    ,ateb_ac_smooth=>ac_smooth           &
    ,ateb_ac_deltat=>ac_deltat           &
    ,ateb_acfactor=>acfactor             &
    ,ateb_ac_copmax=>ac_copmax
use bigxy4_m                               ! Grid interpolation
use cable_ccam, only : proglai           & ! CABLE
    ,soil_struc,cable_pop,progvcmax      &
    ,fwsoil_switch,cable_litter          &
    ,gs_switch,cable_climate,ccycle
use carbpools_m, only : carbpools_init     ! Carbon pools
use cc_mpi                                 ! CC MPI routines
use cc_omp                                 ! CC OpenMP routines
use cfrac_m                                ! Cloud fraction
use cloudmod                               ! Prognostic cloud fraction
use const_phys                             ! Physical constants
use darcdf_m                               ! Netcdf data
use daviesnudge                            ! Far-field nudging
use diag_m                                 ! Diagnostic routines
use dpsdt_m                                ! Vertical velocity
use epst_m                                 ! Off-centre terms
use estab                                  ! Liquid saturation function
use extraout_m                             ! Additional diagnostics
use filnames_m                             ! Filenames
use gdrag_m, only : gdrag_init             ! Gravity wave drag
use getopt_m                               ! Command option parsing
use histave_m                              ! Time average arrays
use indata                                 ! Data initialisation
use indices_m                              ! Grid index arrays
use infile                                 ! Input file routines
use kuocomb_m                              ! JLM convection
use latlong_m                              ! Lat/lon coordinates
use liqwpar_m                              ! Cloud water mixing ratios
use map_m                                  ! Grid map arrays
use mlo, only : zomode,zoseaice          & ! Ocean physics and prognostic arrays
    ,factchseaice,minwater,mxd,mindep    &
    ,alphavis_seaice,alphanir_seaice     &
    ,otaumode,wlev
use mlodynamics                            ! Ocean dynamics
use morepbl_m                              ! Additional boundary layer diagnostics
use newmpar_m                              ! Grid parameters
use nharrs_m, only : nharrs_init           ! Non-hydrostatic atmosphere arrays
use nlin_m                                 ! Atmosphere non-linear dynamics
use nsibd_m                                ! Land-surface arrays
use ozoneread                              ! Ozone input routines
use parm_m                                 ! Model configuration
use parmdyn_m                              ! Dynamics parameters
use parmgeom_m                             ! Coordinate data
use parmhdff_m                             ! Horizontal diffusion parameters
use parmhor_m                              ! Horizontal advection parameters
use pbl_m                                  ! Boundary layer arrays
use permsurf_m, only : permsurf_init       ! Fixed surface arrays
use prec_m                                 ! Precipitation
use raddiag_m                              ! Radiation diagnostic
use river                                  ! River routing
use riverarrays_m                          ! River data
use savuvt_m                               ! Saved dynamic arrays
use savuv1_m                               ! Saved dynamic arrays
use sbar_m                                 ! Saved dynamic arrays
use screen_m                               ! Screen level diagnostics
use seaesfrad_m                            ! SEA-ESF radiation
use setxyz_m                               ! Define CCAM grid
use sigs_m                                 ! Atmosphere sigma levels
use soil_m                                 ! Soil and surface data
use soilsnow_m                             ! Soil, snow and surface data
use stime_m                                ! File date data
use tbar2d_m, only : tbar2d_init           ! Atmosphere dynamics reference temperature
use tkeeps                                 ! TKE-EPS boundary layer
use tracermodule, only : tracerlist      & ! Tracer routines
    ,sitefile,shipfile,writetrpm         &
    ,init_tracer
use tracers_m                              ! Tracer data
use unn_m                                  ! Saved dynamic arrays
use usage_m                                ! Usage message
use uvbar_m                                ! Saved dynamic arrays
use vecs_m, only : vecs_init               ! Eigenvectors for atmosphere dynamics
use vecsuv_m                               ! Map to cartesian coordinates
use vegpar_m                               ! Vegetation arrays
use vvel_m                                 ! Additional vertical velocity
use work2_m                                ! Diagnostic arrays
use work3_m                                ! Mk3 land-surface diagnostic arrays
use work3f_m                               ! Grid work arrays
use work3sav_m                             ! Water and tracer saved arrays
use workglob_m                             ! Additional grid interpolation
use xarrs_m                                ! Saved dynamic arrays
use xyzinfo_m                              ! Grid coordinate arrays

implicit none

include 'kuocom.h'                         ! Convection parameters
include 'version.h'                        ! Model version data

integer, dimension(:), allocatable, save :: dumi
integer ierr, k, new_nproc, ilx, jlx, i, ng
integer isoth, nsig, lapsbot
integer secs_rad, nversion, npa, npb
integer mstn, io_nest, mbd_min
integer opt, nopt
real, dimension(:,:), allocatable, save :: dums
real, dimension(:), allocatable, save :: dumr
real, dimension(8) :: temparray
real, dimension(1) :: gtemparray
real targetlev, dsx, pwatr_l, pwatr
real(kind=8), dimension(:), allocatable, save :: dumr8
character(len=1024) nmlfile
character(len=MAX_ARGLEN) optarg
character(len=60) comm, comment
character(len=47) header
character(len=10) timeval
character(len=8) text, rundate

#ifdef usempi3
integer, dimension(3) :: shsize
#endif
#ifdef debug
real, dimension(1) :: gtemparray
#endif

! version namelist
namelist/defaults/nversion
! main namelist
namelist/cardin/comment,dt,ntau,nwt,npa,npb,nhorps,nperavg,ia,ib, &
    ja,jb,id,jd,iaero,khdif,khor,nhorjlm,mex,mbd,nbd,             &
    mbd_maxscale,mbd_maxgrid,ndi,ndi2,nhor,nlv,nmaxpr,nrad,ntaft, &
    ntsea,ntsur,nvmix,restol,precon,kdate_s,ktime_s,leap,newtop,  &
    mup,lgwd,ngwd,rhsat,nextout,jalbfix,nalpha,nstag,nstagu,      &
    ntbar,nwrite,irest,nrun,nstn,nrungcm,nsib,istn,jstn,iunp,     &
    slat,slon,zstn,name_stn,mh_bs,nritch_t,nt_adv,mfix,mfix_qg,   &
    namip,amipo3,nh,nhstest,nsemble,nspecial,panfg,panzo,         &
    rlatdn,rlatdx,rlongdn,rlongdx,newrough,nglacier,newztsea,     &
    epsp,epsu,epsf,epsh,av_vmod,charnock,chn10,snmin,tss_sh,      &
    vmodmin,zobgin,rlong0,rlat0,schmidt,kbotdav,kbotu,nud_p,      &
    nud_q,nud_t,nud_uv,nud_hrs,nudu_hrs,sigramplow,sigramphigh,   &
    nlocal,nbarewet,nsigmf,io_in,io_nest,io_out,io_rest,          &
    tblock,tbave,localhist,unlimitedhist,synchist,m_fly,          &
    nurban,ktopdav,mbd_mlo,mbd_maxscale_mlo,nud_sst,nud_sss,      &
    mfix_tr,mfix_aero,kbotmlo,ktopmlo,mloalpha,nud_ouv,nud_sfh,   &
    rescrn,helmmeth,nmlo,ol,knh,kblock,nud_aero,cgmap_offset,     &
    cgmap_scale,nriver,atebnmlfile,nud_period,mfix_t,             &
    procformat,procmode,compression,                              & ! file io
    maxtilesize,                                                  & ! OMP
    ch_dust,helim,fc2,sigbot_gwd,alphaj,nmr,qgmin,mstn              ! backwards compatible
! radiation and aerosol namelist
namelist/skyin/mins_rad,sw_resolution,sw_diff_streams,            & ! radiation
    liqradmethod,iceradmethod,so4radmethod,carbonradmethod,       &
    dustradmethod,seasaltradmethod,bpyear,qgmin,lwem_form,        & 
    ch_dust,zvolcemi,aeroindir,so4mtn,carbmtn,saltsmallmtn,       & ! aerosols
    saltlargemtn,                                                 &
    o3_vert_interpolate,o3_time_interpolate                         ! ozone
! file namelist
namelist/datafile/ifile,ofile,albfile,eigenv,icefile,mesonest,    &
    o3file,radfile,restfile,rsmfile,so4tfile,soilfile,sstfile,    &
    surfile,topofile,vegfile,zofile,surf_00,surf_12,laifile,      &
    albnirfile,urbanfile,bathfile,vegprev,vegnext,vegnext2,       &
    cnsdir,salfile,oxidantfile,casafile,phenfile,                 &
    save_aerosols,save_pbl,save_cloud,save_land,save_maxmin,      &
    save_ocean,save_radiation,save_urban,save_carbon,save_river
! convection and cloud microphysics namelist
namelist/kuonml/alflnd,alfsea,cldh_lnd,cldm_lnd,cldl_lnd,         & ! convection
    cldh_sea,cldm_sea,cldl_sea,convfact,convtime,shaltime,        &
    detrain,detrainx,dsig2,dsig4,entrain,fldown,iterconv,ksc,     &
    kscmom,kscsea,ldr,mbase,mdelay,methdetr,methprec,nbase,       &
    ncvcloud,ncvmix,nevapcc,nkuo,nrhcrit,                         &
    nstab_cld,nuvconv,rhcv,rhmois,rhsat,sigcb,sigcll,sig_ct,      &
    sigkscb,sigksct,tied_con,tied_over,tied_rh,comm,acon,bcon,    &
    rcm,                                                          &
    rcrit_l,rcrit_s,ncloud,nclddia,nmr,nevapls                      ! cloud
! boundary layer turbulence and gravity wave namelist
namelist/turbnml/be,cm0,ce0,ce1,ce2,ce3,cq,ent0,ent1,entc0,dtrc0, & !EDMF PBL scheme
    m0,b1,b2,buoymeth,maxdts,mintke,mineps,minl,maxl,             &
    stabmeth,tke_umin,tkemeth,qcmf,ezmin,ent_min,                 &
    amxlsq,                                                       & !JH PBL scheme
    ngwd,helim,fc2,sigbot_gwd,alphaj                                !GWdrag
! land, urban and carbon namelist
namelist/landnml/proglai,ccycle,soil_struc,cable_pop,             & ! CABLE
    progvcmax,fwsoil_switch,cable_litter,                         &
    gs_switch,cable_climate,                                      &
    ateb_energytol,ateb_resmeth,ateb_useonewall,ateb_zohmeth,     & ! urban
    ateb_acmeth,ateb_nrefl,ateb_vegmode,ateb_soilunder,           &
    ateb_conductmeth,ateb_scrnmeth,ateb_wbrelaxc,ateb_wbrelaxr,   &
    ateb_lweff,ateb_ncyits,ateb_nfgits,ateb_tol,ateb_alpha,       &
    ateb_zosnow,ateb_snowemiss,ateb_maxsnowalpha,                 &
    ateb_minsnowalpha,ateb_maxsnowden,ateb_minsnowden,            &
    ateb_refheight,ateb_zomratio,ateb_zocanyon,ateb_zoroof,       &
    ateb_maxrfwater,ateb_maxrdwater,ateb_maxrfsn,ateb_maxrdsn,    &
    ateb_maxvwatf,ateb_intairtmeth,ateb_intmassmeth,              &
    ateb_cvcoeffmeth,ateb_statsmeth,ateb_behavmeth,               &
    ateb_infilmeth,ateb_ac_heatcap,ateb_ac_coolcap,               &
    ateb_ac_heatprop,ateb_ac_coolprop,ateb_ac_smooth,             &
    ateb_ac_deltat,ateb_acfactor,ateb_ac_copmax,                  &
    siburbanfrac
! ocean namelist
namelist/mlonml/mlodiff,ocnsmag,ocneps,usetide,zomode,zoseaice,   &
    factchseaice,minwater,mxd,mindep,mlomfix,otaumode,            &
    alphavis_seaice,alphanir_seaice,mlojacobi,                    &
    rivermd,basinmd,rivercoeff                                      ! River
! tracer namelist
namelist/trfiles/tracerlist,sitefile,shipfile,writetrpm


!--------------------------------------------------------------
! READ COMMAND LINE OPTIONS
nmlfile = "input"
do
  call getopt("hc:",nopt,opt,optarg)
  if ( opt==-1 ) exit  ! End of options
  select case ( char(opt) )
    case ( "h" )
      call help
    case ( "c" )
      nmlfile = optarg
    case default
      if ( myid==0 ) write(6,*) "ERROR: Unknown command line option ",char(opt)
      call usage
  end select
end do


!--------------------------------------------------------------
! READ NAMELISTS AND SET PARAMETER DEFAULTS
nversion         = 0
comm             = ' '
comment          = ' '
ia               = -1   ! diagnostic index
ib               = -1   ! diagnostic index
ntbar            = -1
ktau             = 0
ol               = 20   ! default ocean levels
nhor             = -157
nhorps           = -1
khor             = -8
khdif            = 2
nhorjlm          = 1
ngas             = 0
atebnmlfile      = 0
ateb_energytol   = 1._8
ateb_intairtmeth = 0
ateb_intmassmeth = 0
lapsbot          = 0
io_nest          = 1

! All processors read the namelist, so no MPI comms are needed
if ( myid==0 ) then
  open(99,file=trim(nmlfile),form="formatted",status="old",iostat=ierr)
  if ( ierr/=0 ) then
    write(6,*) "ERROR: Cannot open namelist ",trim(nmlfile)  
    call ccmpi_abort(-1)
  end if
  read(99, defaults)
end if
call ccmpi_bcast(nversion,0,comm_world)
if ( nversion/=0 ) then
  call change_defaults(nversion)
end if
allocate( dumr(33), dumi(115) ) 
dumr(:) = 0.
dumi(:) = 0
if ( myid==0 ) then
  read(99, cardin)
  dumr(1)   = dt
  dumr(2)   = restol
  dumr(3)   = panfg
  dumr(4)   = panzo
  dumr(5)   = rlatdn
  dumr(6)   = rlatdx
  dumr(7)   = rlongdn
  dumr(8)   = rlongdx
  dumr(9)   = epsp
  dumr(10)  = epsu
  dumr(11)  = epsf
  dumr(12)  = epsh
  dumr(13)  = av_vmod
  dumr(14)  = charnock
  dumr(15)  = chn10
  dumr(16)  = snmin
  dumr(17)  = tss_sh
  dumr(18)  = vmodmin
  dumr(19)  = zobgin
  dumr(20)  = rlong0
  dumr(21)  = rlat0
  dumr(22)  = schmidt
  dumr(23)  = sigramplow
  dumr(24)  = sigramphigh
  dumr(25)  = cgmap_offset
  dumr(26)  = cgmap_scale
  dumr(27)  = ch_dust
  dumr(28)  = helim
  dumr(29)  = fc2
  dumr(30)  = sigbot_gwd
  dumr(31)  = alphaj
  dumr(32)  = qgmin
  dumr(33)  = rhsat
  dumi(1)   = ntau
  dumi(2)   = nwt
  dumi(3)   = npa
  dumi(4)   = npb
  dumi(5)   = nhorps
  dumi(6)   = nperavg
  dumi(7)   = ia
  dumi(8)   = ib
  dumi(9)   = ja
  dumi(10)  = jb
  dumi(11)  = id
  dumi(12)  = jd
  dumi(13)  = iaero
  dumi(14)  = khdif
  dumi(15)  = khor
  dumi(16)  = nhorjlm
  dumi(17)  = mex
  dumi(18)  = mbd
  dumi(19)  = nbd
  dumi(20)  = mbd_maxscale
  dumi(21)  = mbd_maxgrid
  dumi(22)  = ndi
  dumi(23)  = ndi2
  dumi(24)  = nhor
  dumi(25)  = nlv
  dumi(26)  = nmaxpr
  dumi(27)  = nrad
  dumi(28)  = ntaft
  dumi(29)  = ntsea
  dumi(30)  = ntsur
  dumi(31)  = nvmix
  dumi(32)  = precon
  dumi(33)  = kdate_s
  dumi(34)  = ktime_s
  dumi(35)  = leap
  dumi(36)  = newtop
  dumi(37)  = mup
  dumi(38)  = lgwd
  dumi(39)  = ngwd
  dumi(40)  = nextout
  dumi(41)  = jalbfix
  dumi(42)  = nalpha
  dumi(43)  = nstag
  dumi(44)  = nstagu
  dumi(45)  = ntbar
  dumi(46)  = nwrite
  dumi(47)  = irest
  dumi(48)  = nrun
  dumi(49)  = nstn
  dumi(50)  = nrungcm
  dumi(51)  = nsib
  dumi(52)  = mh_bs
  dumi(53)  = nritch_t
  dumi(54)  = nt_adv
  dumi(55)  = mfix
  dumi(56)  = mfix_qg
  dumi(57)  = namip
  if ( amipo3 ) dumi(58) = 1
  dumi(59)  = nh
  dumi(60)  = nhstest
  dumi(61)  = nsemble
  dumi(62)  = nspecial
  dumi(63)  = newrough
  dumi(64)  = nglacier
  dumi(65)  = newztsea
  dumi(66)  = kbotdav
  dumi(67)  = kbotu
  dumi(68)  = nud_p
  dumi(69)  = nud_q
  dumi(70)  = nud_t
  dumi(71)  = nud_uv
  dumi(72)  = nud_hrs
  dumi(73)  = nudu_hrs
  dumi(74)  = nlocal
  dumi(75)  = nbarewet
  dumi(76)  = nsigmf
  dumi(77)  = io_in
  dumi(78)  = io_nest
  dumi(79)  = io_out
  dumi(80)  = io_rest
  dumi(81)  = tblock
  dumi(82)  = tbave
  if ( localhist) dumi(83) = 1
  if ( unlimitedhist ) dumi(84) = 1
  if ( synchist ) dumi(85) = 1
  dumi(86)  = m_fly
  dumi(87)  = nurban
  dumi(88)  = ktopdav
  dumi(89)  = mbd_mlo
  dumi(90)  = mbd_maxscale_mlo
  dumi(91)  = nud_sst
  dumi(92)  = nud_sss
  dumi(93)  = mfix_tr
  dumi(94)  = mfix_aero
  dumi(95)  = kbotmlo
  dumi(96)  = ktopmlo
  dumi(97)  = mloalpha
  dumi(98)  = nud_ouv
  dumi(99)  = nud_sfh
  dumi(100)  = rescrn
  dumi(101) = helmmeth
  dumi(102) = nmlo
  dumi(103) = ol
  dumi(104) = knh
  dumi(105) = kblock
  dumi(106) = nud_aero
  dumi(107) = nriver
  dumi(108) = atebnmlfile
  dumi(109) = nud_period
  if ( procformat ) dumi(110) = 1
  dumi(111) = procmode
  dumi(112) = compression
  dumi(113) = nmr
  dumi(114) = maxtilesize
  dumi(115) = mfix_t
end if
call ccmpi_bcast(dumr,0,comm_world)
call ccmpi_bcast(dumi,0,comm_world)
dt               = dumr(1)
restol           = dumr(2)
panfg            = dumr(3)
panzo            = dumr(4)
rlatdn           = dumr(5)
rlatdx           = dumr(6)
rlongdn          = dumr(7)
rlongdx          = dumr(8)
epsp             = dumr(9)
epsu             = dumr(10)
epsf             = dumr(11)
epsh             = dumr(12)
av_vmod          = dumr(13)
charnock         = dumr(14)
chn10            = dumr(15)
snmin            = dumr(16)
tss_sh           = dumr(17)
vmodmin          = dumr(18)
zobgin           = dumr(19)
rlong0           = dumr(20)
rlat0            = dumr(21)
schmidt          = dumr(22)
sigramplow       = dumr(23)
sigramphigh      = dumr(24)
cgmap_offset     = dumr(25)
cgmap_scale      = dumr(26)
ch_dust          = dumr(27)
helim            = dumr(28)
fc2              = dumr(29)
sigbot_gwd       = dumr(30)
alphaj           = dumr(31)
qgmin            = dumr(32)
rhsat            = dumr(33)
ntau             = dumi(1)
nwt              = dumi(2)
npa              = dumi(3)
npb              = dumi(4)
nhorps           = dumi(5)
nperavg          = dumi(6)
ia               = dumi(7)
ib               = dumi(8)
ja               = dumi(9)
jb               = dumi(10)
id               = dumi(11)
jd               = dumi(12)
iaero            = dumi(13)
khdif            = dumi(14)
khor             = dumi(15)
nhorjlm          = dumi(16)
mex              = dumi(17)
mbd              = dumi(18)
nbd              = dumi(19)
mbd_maxscale     = dumi(20)
mbd_maxgrid      = dumi(21)
ndi              = dumi(22)
ndi2             = dumi(23)
nhor             = dumi(24)
nlv              = dumi(25)
nmaxpr           = dumi(26)
nrad             = dumi(27)
ntaft            = dumi(28)
ntsea            = dumi(29)
ntsur            = dumi(30)
nvmix            = dumi(31)
precon           = dumi(32)
kdate_s          = dumi(33)
ktime_s          = dumi(34)
leap             = dumi(35)
newtop           = dumi(36)
mup              = dumi(37)
lgwd             = dumi(38)
ngwd             = dumi(39)
nextout          = dumi(40)
jalbfix          = dumi(41)
nalpha           = dumi(42)
nstag            = dumi(43)
nstagu           = dumi(44)
ntbar            = dumi(45)
nwrite           = dumi(46)
irest            = dumi(47)
nrun             = dumi(48)
nstn             = dumi(49)
nrungcm          = dumi(50)
nsib             = dumi(51)
mh_bs            = dumi(52)
nritch_t         = dumi(53)
nt_adv           = dumi(54)
mfix             = dumi(55)
mfix_qg          = dumi(56)
namip            = dumi(57)
amipo3           = dumi(58)==1
nh               = dumi(59)
nhstest          = dumi(60)
nsemble          = dumi(61)
nspecial         = dumi(62)
newrough         = dumi(63)
nglacier         = dumi(64)
newztsea         = dumi(65)
kbotdav          = dumi(66)
kbotu            = dumi(67)
nud_p            = dumi(68)
nud_q            = dumi(69)
nud_t            = dumi(70)
nud_uv           = dumi(71)
nud_hrs          = dumi(72)
nudu_hrs         = dumi(73)
nlocal           = dumi(74)
nbarewet         = dumi(75)
nsigmf           = dumi(76)
io_in            = dumi(77)
io_nest          = dumi(78)
io_out           = dumi(79)
io_rest          = dumi(80)
tblock           = dumi(81)
tbave            = dumi(82)
localhist        = dumi(83)==1
unlimitedhist    = dumi(84)==1
synchist         = dumi(85)==1
m_fly            = dumi(86)
nurban           = dumi(87)
ktopdav          = dumi(88)
mbd_mlo          = dumi(89)
mbd_maxscale_mlo = dumi(90)
nud_sst          = dumi(91)
nud_sss          = dumi(92)
mfix_tr          = dumi(93)
mfix_aero        = dumi(94)
kbotmlo          = dumi(95)
ktopmlo          = dumi(96)
mloalpha         = dumi(97)
nud_ouv          = dumi(98)
nud_sfh          = dumi(99)
rescrn           = dumi(100)
helmmeth         = dumi(101)
nmlo             = dumi(102)
ol               = dumi(103)
knh              = dumi(104)
kblock           = dumi(105)
nud_aero         = dumi(106)
nriver           = dumi(107)
atebnmlfile      = dumi(108)
nud_period       = dumi(109)
procformat       = dumi(110)==1
procmode         = dumi(111)
compression      = dumi(112)
nmr              = dumi(113)
maxtilesize      = dumi(114)
mfix_t           = dumi(115)
deallocate( dumr, dumi )
if ( nstn>0 ) then
  call ccmpi_bcast(istn(1:nstn),0,comm_world)
  call ccmpi_bcast(jstn(1:nstn),0,comm_world)
  call ccmpi_bcast(iunp(1:nstn),0,comm_world)
  call ccmpi_bcast(slat(1:nstn),0,comm_world)
  call ccmpi_bcast(slon(1:nstn),0,comm_world)
  call ccmpi_bcast(zstn(1:nstn),0,comm_world)
  do i = 1,nstn
    call ccmpi_bcast(name_stn(i),0,comm_world)
  end do
end if
allocate( dumr(8), dumi(10) )
dumr = 0.
dumi = 0
if ( myid==0 ) then
  read(99, skyin)
  dumr(1)  = bpyear
  dumr(2)  = qgmin
  dumr(3)  = ch_dust
  dumr(4)  = zvolcemi
  dumr(5)  = so4mtn
  dumr(6)  = carbmtn
  dumr(7)  = saltsmallmtn
  dumr(8)  = saltlargemtn
  dumi(1)  = mins_rad
  dumi(2)  = liqradmethod
  dumi(3)  = iceradmethod
  dumi(4)  = so4radmethod
  dumi(5)  = carbonradmethod
  dumi(6)  = dustradmethod
  dumi(7)  = seasaltradmethod
  dumi(8)  = aeroindir
  dumi(9)  = o3_vert_interpolate
  dumi(10) = o3_time_interpolate
end if
call ccmpi_bcast(dumr,0,comm_world)
call ccmpi_bcast(dumi,0,comm_world)
call ccmpi_bcast(sw_resolution,0,comm_world)
call ccmpi_bcast(lwem_form,0,comm_world)
bpyear              = dumr(1)
qgmin               = dumr(2)
ch_dust             = dumr(3)
zvolcemi            = dumr(4)
so4mtn              = dumi(5)
carbmtn             = dumr(6)
saltsmallmtn        = dumr(7)
saltlargemtn        = dumr(8)
mins_rad            = dumi(1)
liqradmethod        = dumi(2)
iceradmethod        = dumi(3)
so4radmethod        = dumi(4)
carbonradmethod     = dumi(5)
dustradmethod       = dumi(6)
seasaltradmethod    = dumi(7)
aeroindir           = dumi(8)
o3_vert_interpolate = dumi(9)
o3_time_interpolate = dumi(10)
deallocate( dumr, dumi )
allocate( dumi(10) )
dumi = 0
if ( myid==0 ) then
  read(99, datafile)
  if ( save_aerosols ) dumi(1)=1
  if ( save_pbl ) dumi(2)=1
  if ( save_cloud ) dumi(3)=1
  if ( save_land ) dumi(4)=1
  if ( save_maxmin ) dumi(5)=1
  if ( save_ocean ) dumi(6)=1
  if ( save_radiation ) dumi(7)=1
  if ( save_urban ) dumi(8)=1
  if ( save_carbon ) dumi(9)=1
  if ( save_river ) dumi(10)=1
end if
call ccmpi_bcast(dumi,0,comm_world)
call ccmpi_bcast(ifile,0,comm_world)
call ccmpi_bcast(ofile,0,comm_world)
call ccmpi_bcast(mesonest,0,comm_world)
call ccmpi_bcast(restfile,0,comm_world)
call ccmpi_bcast(surfile,0,comm_world)
call ccmpi_bcast(surf_00,0,comm_world)
call ccmpi_bcast(surf_12,0,comm_world)
call ccmpi_bcast(cnsdir,0,comm_world)
call ccmpi_bcast(vegprev,0,comm_world)
call ccmpi_bcast(vegnext,0,comm_world)
call ccmpi_bcast(vegnext2,0,comm_world)
!call ccmpi_bcast(albfile,0,comm_world)
!call ccmpi_bcast(eigenv,0,comm_world)
!call ccmpi_bcast(icefile,0,comm_world)
!call ccmpi_bcast(o3file,0,comm_world)
!call ccmpi_bcast(radfile,0,comm_world)
!call ccmpi_bcast(rsmfile,0,comm_world)
!call ccmpi_bcast(so4tfile,0,comm_world)
!call ccmpi_bcast(soilfile,0,comm_world)
!call ccmpi_bcast(sstfile,0,comm_world)
!call ccmpi_bcast(topofile,0,comm_world)
!call ccmpi_bcast(vegfile,0,comm_world)
!call ccmpi_bcast(zofile,0,comm_world)
!call ccmpi_bcast(laifile,0,comm_world)
!call ccmpi_bcast(albnirfile,0,comm_world)
!call ccmpi_bcast(urbanfile,0,comm_world)
!call ccmpi_bcast(bathfile,0,comm_world)
!call ccmpi_bcast(salfile,0,comm_world)
!call ccmpi_bcast(oxidantfile,0,comm_world)
!call ccmpi_bcast(casafile,0,comm_world)
!call ccmpi_bcast(phenfile,0,comm_world)
save_aerosols  = dumi(1)==1
save_pbl       = dumi(2)==1
save_cloud     = dumi(3)==1
save_land      = dumi(4)==1
save_maxmin    = dumi(5)==1
save_ocean     = dumi(6)==1
save_radiation = dumi(7)==1
save_urban     = dumi(8)==1
save_carbon    = dumi(9)==1
save_river     = dumi(10)==1
deallocate( dumi )
allocate( dumr(33), dumi(21) )
dumr = 0.
dumi = 0
if ( myid==0 ) then
  read(99, kuonml)
  dumr(1)  = alflnd
  dumr(2)  = alfsea
  dumr(3)  = cldh_lnd
  dumr(4)  = cldm_lnd
  dumr(5)  = cldl_lnd
  dumr(6)  = cldh_sea
  dumr(7)  = cldm_sea
  dumr(8)  = cldl_sea
  dumr(9)  = convfact
  dumr(10) = convtime
  dumr(11) = shaltime
  dumr(12) = detrain
  dumr(13) = detrainx
  dumr(14) = dsig2
  dumr(15) = dsig4
  dumr(16) = entrain
  dumr(17) = fldown
  dumr(18) = rhcv
  dumr(19) = rhmois
  dumr(20) = rhsat
  dumr(21) = sigcb
  dumr(22) = sigcll
  dumr(23) = sig_ct
  dumr(24) = sigkscb
  dumr(25) = sigksct
  dumr(26) = tied_con
  dumr(27) = tied_over
  dumr(28) = tied_rh
  dumr(29) = acon
  dumr(30) = bcon
  dumr(31) = rcm
  dumr(32) = rcrit_l
  dumr(33) = rcrit_s
  dumi(1)  = iterconv
  dumi(2)  = ksc
  dumi(3)  = kscmom
  dumi(4)  = kscsea
  dumi(5)  = ldr
  dumi(6)  = mbase
  dumi(7)  = mdelay
  dumi(8)  = methdetr
  dumi(9)  = methprec
  dumi(10) = nbase
  dumi(11) = ncvcloud
  dumi(12) = ncvmix
  dumi(13) = nevapcc
  dumi(14) = nkuo
  dumi(15) = nrhcrit
  dumi(16) = nstab_cld
  dumi(17) = nuvconv
  dumi(18) = ncloud
  dumi(19) = nclddia
  dumi(20) = nmr
  dumi(21) = nevapls
end if
call ccmpi_bcast(dumr,0,comm_world)
call ccmpi_bcast(dumi,0,comm_world)
alflnd         = dumr(1)
alfsea         = dumr(2)
cldh_lnd       = dumr(3)
cldm_lnd       = dumr(4) 
cldl_lnd       = dumr(5)
cldh_sea       = dumr(6) 
cldm_sea       = dumr(7)
cldl_sea       = dumr(8)
convfact       = dumr(9)
convtime       = dumr(10)
shaltime       = dumr(11) 
detrain        = dumr(12)
detrainx       = dumr(13)
dsig2          = dumr(14)
dsig4          = dumr(15)
entrain        = dumr(16)
fldown         = dumr(17)
rhcv           = dumr(18)
rhmois         = dumr(19)
rhsat          = dumr(20)
sigcb          = dumr(21)
sigcll         = dumr(22)
sig_ct         = dumr(23)
sigkscb        = dumr(24)
sigksct        = dumr(25)
tied_con       = dumr(26)
tied_over      = dumr(27)
tied_rh        = dumr(28)
acon           = dumr(29)
bcon           = dumr(30)
rcm            = dumr(31)
rcrit_l        = dumr(32)
rcrit_s        = dumr(33)
iterconv       = dumi(1) 
ksc            = dumi(2)
kscmom         = dumi(3)
kscsea         = dumi(4)
ldr            = dumi(5)
mbase          = dumi(6)
mdelay         = dumi(7)
methdetr       = dumi(8) 
methprec       = dumi(9)
nbase          = dumi(10)
ncvcloud       = dumi(11)
ncvmix         = dumi(12)
nevapcc        = dumi(13)
nkuo           = dumi(14)
nrhcrit        = dumi(15)
nstab_cld      = dumi(16)
nuvconv        = dumi(17)
ncloud         = dumi(18)
nclddia        = dumi(19) 
nmr            = dumi(20)
nevapls        = dumi(21)
deallocate( dumr, dumi )
allocate( dumr(29), dumi(4) )
dumr = 0.
dumi = 0
if ( myid==0 ) then
  read(99, turbnml, iostat=ierr)  ! try reading PBL and GWdrag namelist
  if ( ierr/=0 ) then
    rewind(99)
    ! if namelist is not missing, then trigger an error message
    if ( .not.is_iostat_end(ierr) ) read(99, turbnml)
  end if
  dumr(1)  = be
  dumr(2)  = cm0
  dumr(3)  = ce0
  dumr(4)  = ce1
  dumr(5)  = ce2
  dumr(6)  = ce3
  dumr(7)  = cq
  dumr(8)  = ent0
  dumr(9)  = ent1
  dumr(10) = entc0
  dumr(11) = dtrc0
  dumr(12) = m0
  dumr(13) = b1
  dumr(14) = b2
  dumr(15) = maxdts
  dumr(16) = mintke
  dumr(17) = mineps
  dumr(18) = minl
  dumr(19) = maxl
  dumr(20) = tke_umin
  dumr(21) = qcmf
  dumr(22) = ezmin
  dumr(23) = amxlsq
  dumr(25) = helim
  dumr(26) = fc2
  dumr(27) = sigbot_gwd
  dumr(28) = alphaj
  dumr(29) = ent_min
  dumi(1)  = buoymeth
  dumi(2)  = stabmeth
  dumi(3)  = tkemeth
  dumi(4)  = ngwd
end if
call ccmpi_bcast(dumr,0,comm_world)
call ccmpi_bcast(dumi,0,comm_world)
be         = dumr(1)
cm0        = dumr(2)
ce0        = dumr(3)
ce1        = dumr(4)
ce2        = dumr(5)
ce3        = dumr(6)
cq         = dumr(7)
ent0       = dumr(8)
ent1       = dumr(9)
entc0      = dumr(10)
dtrc0      = dumr(11)
m0         = dumr(12)
b1         = dumr(13)
b2         = dumr(14)
maxdts     = dumr(15)
mintke     = dumr(16)
mineps     = dumr(17) 
minl       = dumr(18)
maxl       = dumr(19)
tke_umin   = dumr(20)
qcmf       = dumr(21)
ezmin      = dumr(22)
amxlsq     = dumr(23)
helim      = dumr(25)
fc2        = dumr(26)
sigbot_gwd = dumr(27)
alphaj     = dumr(28)
ent_min    = dumr(29)
buoymeth   = dumi(1)
stabmeth   = dumi(2)
tkemeth    = dumi(3)
ngwd       = dumi(4)
deallocate( dumr, dumi )
allocate( dumr8(1), dumr(26), dumi(29) )
dumr8 = 0._8
dumr = 0.
dumi = 0
if ( myid==0 ) then
  read(99, landnml, iostat=ierr)  ! try reading land/carbon namelist
  if ( ierr/=0 ) then
    rewind(99)
    ! if namelist is not missing, then trigger an error message
    if ( .not.is_iostat_end(ierr) ) read(99, landnml)
  end if
  dumr8(1) = ateb_energytol
  dumr(1)  = ateb_tol
  dumr(2)  = ateb_alpha
  dumr(3)  = ateb_zosnow
  dumr(4)  = ateb_snowemiss
  dumr(5)  = ateb_maxsnowalpha
  dumr(6)  = ateb_minsnowalpha
  dumr(7)  = ateb_maxsnowden
  dumr(8)  = ateb_minsnowden
  dumr(9)  = ateb_refheight
  dumr(10) = ateb_zomratio
  dumr(11) = ateb_zocanyon
  dumr(12) = ateb_zoroof
  dumr(13) = ateb_maxrfwater
  dumr(14) = ateb_maxrdwater
  dumr(15) = ateb_maxrfsn
  dumr(16) = ateb_maxrdsn
  dumr(17) = ateb_maxvwatf
  dumr(18) = ateb_ac_heatcap
  dumr(19) = ateb_ac_coolcap
  dumr(20) = ateb_ac_heatprop
  dumr(21) = ateb_ac_coolprop
  dumr(22) = ateb_ac_smooth
  dumr(23) = ateb_ac_deltat
  dumr(24) = ateb_acfactor
  dumr(25) = ateb_ac_copmax
  dumr(26) = siburbanfrac
  dumi(1)  = proglai
  dumi(2)  = ccycle
  dumi(3)  = soil_struc
  dumi(4)  = cable_pop
  dumi(5)  = progvcmax
  dumi(6)  = fwsoil_switch
  dumi(7)  = cable_litter
  dumi(8)  = gs_switch
  dumi(9)  = cable_climate
  dumi(10) = ateb_resmeth
  dumi(11) = ateb_useonewall
  dumi(12) = ateb_zohmeth
  dumi(13) = ateb_acmeth
  dumi(14) = ateb_nrefl
  dumi(15) = ateb_vegmode
  dumi(16) = ateb_soilunder
  dumi(17) = ateb_conductmeth
  dumi(18) = ateb_scrnmeth
  dumi(19) = ateb_wbrelaxc
  dumi(20) = ateb_wbrelaxr
  dumi(21) = ateb_lweff
  dumi(22) = ateb_ncyits
  dumi(23) = ateb_nfgits
  dumi(24) = ateb_intairtmeth
  dumi(25) = ateb_intmassmeth
  dumi(26) = ateb_cvcoeffmeth
  dumi(27) = ateb_statsmeth
  dumi(28) = ateb_behavmeth
  dumi(29) = ateb_infilmeth
end if
call ccmpi_bcastr8(dumr8,0,comm_world)
call ccmpi_bcast(dumr,0,comm_world)
call ccmpi_bcast(dumi,0,comm_world)
ateb_energytol    = dumr8(1)
ateb_tol          = dumr(1)
ateb_alpha        = dumr(2)
ateb_zosnow       = dumr(3)
ateb_snowemiss    = dumr(4)
ateb_maxsnowalpha = dumr(5)
ateb_minsnowalpha = dumr(6)
ateb_maxsnowden   = dumr(7)
ateb_minsnowden   = dumr(8)
ateb_refheight    = dumr(9) 
ateb_zomratio     = dumr(10)
ateb_zocanyon     = dumr(11)
ateb_zoroof       = dumr(12)
ateb_maxrfwater   = dumr(13)
ateb_maxrdwater   = dumr(14)
ateb_maxrfsn      = dumr(15)
ateb_maxrdsn      = dumr(16)
ateb_maxvwatf     = dumr(17) 
ateb_ac_heatcap   = dumr(18)
ateb_ac_coolcap   = dumr(19)
ateb_ac_heatprop  = dumr(20)
ateb_ac_coolprop  = dumr(21)
ateb_ac_smooth    = dumr(22)
ateb_ac_deltat    = dumr(23)
ateb_acfactor     = dumr(24)
ateb_ac_copmax    = dumr(25)
siburbanfrac      = dumr(26) 
proglai           = dumi(1)
ccycle            = dumi(2)
soil_struc        = dumi(3)
cable_pop         = dumi(4)
progvcmax         = dumi(5)
fwsoil_switch     = dumi(6)
cable_litter      = dumi(7)
gs_switch         = dumi(8)
cable_climate     = dumi(9)
ateb_resmeth      = dumi(10)
ateb_useonewall   = dumi(11)
ateb_zohmeth      = dumi(12)
ateb_acmeth       = dumi(13)
ateb_nrefl        = dumi(14) 
ateb_vegmode      = dumi(15) 
ateb_soilunder    = dumi(16)
ateb_conductmeth  = dumi(17) 
ateb_scrnmeth     = dumi(18)
ateb_wbrelaxc     = dumi(19) 
ateb_wbrelaxr     = dumi(20) 
ateb_lweff        = dumi(21) 
ateb_ncyits       = dumi(22)
ateb_nfgits       = dumi(23) 
ateb_intairtmeth  = dumi(24)
ateb_intmassmeth  = dumi(25) 
ateb_cvcoeffmeth  = dumi(26) 
ateb_statsmeth    = dumi(27) 
ateb_behavmeth    = dumi(28) 
ateb_infilmeth    = dumi(29) 
deallocate( dumr, dumi )
allocate( dumr(10), dumi(8) )
dumr = 0.
dumi = 0
if ( myid==0 ) then
  read(99, mlonml, iostat=ierr)   ! try reading ocean namelist
  if ( ierr/=0 ) then
    rewind(99)
    ! if namelist is not missing, then trigger an error message
    if ( .not.is_iostat_end(ierr) ) read(99, mlonml)
  end if
  dumr(1)  = ocnsmag
  dumr(2)  = ocneps
  dumr(3)  = zoseaice
  dumr(4)  = factchseaice
  dumr(5)  = minwater
  dumr(6)  = mxd
  dumr(7)  = mindep
  dumr(8)  = alphavis_seaice
  dumr(9)  = alphanir_seaice
  dumr(10) = rivercoeff
  dumi(1)  = mlodiff
  dumi(2)  = usetide
  dumi(3)  = zomode
  dumi(4)  = mlomfix
  dumi(5)  = otaumode
  dumi(6)  = rivermd
  dumi(7)  = basinmd
  dumi(8) = mlojacobi
end if
call ccmpi_bcast(dumr,0,comm_world)
call ccmpi_bcast(dumi,0,comm_world)
ocnsmag         = dumr(1) 
ocneps          = dumr(2) 
zoseaice        = dumr(3) 
factchseaice    = dumr(4)
minwater        = dumr(5) 
mxd             = dumr(6)
mindep          = dumr(7)
alphavis_seaice = dumr(8)
alphanir_seaice = dumr(9)
rivercoeff      = dumr(10)
mlodiff         = dumi(1)
usetide         = dumi(2) 
zomode          = dumi(3) 
mlomfix         = dumi(4) 
otaumode        = dumi(5) 
rivermd         = dumi(6)
basinmd         = dumi(7)
mlojacobi       = dumi(8)
deallocate( dumr, dumi )
allocate( dumi(1) )
dumi = 0
if ( myid==0 ) then
  read(99, trfiles, iostat=ierr)  ! try reading tracer namelist
  if ( ierr/=0 ) then
    rewind(99)
    ! if namelist is not missing, then trigger an error message
    if ( .not.is_iostat_end(ierr) ) read(99, trfiles)
  end if
  if ( writetrpm ) dumi(1) = 1
end if
call ccmpi_bcast(tracerlist,0,comm_world)
if ( tracerlist/=' ' ) then
  call ccmpi_bcast(dumi,0,comm_world)
  call ccmpi_bcast(sitefile,0,comm_world)
  call ccmpi_bcast(shipfile,0,comm_world)
  writetrpm = dumi(1)==1
end if  
deallocate( dumi )
if ( myid==0 ) then
  close(99)
end if
if ( dt<=0. ) then
  write(6,*) "ERROR: dt must be greather than zero"
  call ccmpi_abort(-1)
end if
if ( dt>3600. ) then
  write(6,*) "ERROR: dt must be less or equal to 3600."
  call ccmpi_abort(-1)
end if
nperday = nint(24.*3600./dt)           ! time-steps in one day
nperhr  = nint(3600./dt)               ! time-steps in one hour
if ( nwt==-99 )     nwt = nperday      ! set default nwt to 24 hours
if ( nperavg==-99 ) nperavg = nwt      ! set default nperavg to nwt
if ( nwrite==0 )    nwrite = nperday   ! only used for outfile IEEE
if ( nwt<=0 ) then
  write(6,*) "ERROR: nwt must be greater than zero or nwt=-99"
  call ccmpi_abort(-1)
end if
if ( nmlo/=0 .and. abs(nmlo)<=9 ) then ! set ocean levels if required
  ol = max( ol, 1 )
else
  ol = 0
end if
wlev     = ol                   ! set nmlo and nmlodynamics ocean levels
mindep   = max( 0., mindep )    ! limit ocean minimum depth below sea-level
minwater = max( 0., minwater )  ! limit ocean minimum water level
if ( nmlo>=2 ) nriver = 1       ! turn on rivers for dynamic ocean model (output in history file)
if ( nmlo<=-2 ) nriver = -1     ! turn on rivers for dynamic ocean model (no output in history file)
tke_umin = vmodmin              ! minimum wind speed for surface fluxes


!--------------------------------------------------------------
! READ TOPOGRAPHY FILE TO DEFINE CONFORMAL CUBIC GRID

il_g    = 48 ! default global grid size
rlong0  = 0. ! default longitude
rlat0   = 0. ! default latitude
schmidt = 1. ! default schmidt factor for grid stretching
kl      = 18 ! default number of vertical levels

if ( myid==0 ) then
  if ( io_in<=4 ) then
    ! open topo file and check its dimensions
    ! here used to supply rlong0,rlat0,schmidt
    ! Remander of topo file is read in indata.f90
    call ccnf_open(topofile,ncidtopo,ierr)
    if ( ierr==0 ) then
      ! Netcdf format
      lnctopo = 1 ! flag indicating netcdf file
      call ccnf_inq_dimlen(ncidtopo,'longitude',ilx)
      call ccnf_inq_dimlen(ncidtopo,'latitude',jlx)
      call ccnf_get_attg(ncidtopo,'lon0',rlong0)
      call ccnf_get_attg(ncidtopo,'lat0',rlat0)
      call ccnf_get_attg(ncidtopo,'schmidt',schmidt) 
    else
      ! ASCII format      
      lnctopo = 0 ! flag indicating ASCII file
      open(66,file=topofile,recl=2000,status='old',iostat=ierr)
      if ( ierr /= 0 ) then
        write(6,*) "Error opening topofile ",trim(topofile)
        call ccmpi_abort(-1)
      end if
      read(66,*) ilx,jlx,rlong0,rlat0,schmidt,dsx,header
    end if ! (ierr==0) ..else..
    il_g = ilx        
  end if
  ! store grid dimensions for broadcast below
  temparray(1) = rlong0
  temparray(2) = rlat0
  temparray(3) = schmidt
  temparray(4) = real(il_g)
end if      ! (myid==0)


!--------------------------------------------------------------
! READ EIGENV FILE TO DEFINE VERTICAL LEVELS

if ( myid==0 ) then
  ! Remanded of file is read in indata.f90
  open(28,file=eigenv,status='old',form='formatted',iostat=ierr)
  if ( ierr/=0 ) then
    write(6,*) "Error opening eigenv file ",trim(eigenv)
    call ccmpi_abort(-1)
  end if
  read(28,*)kl,lapsbot,isoth,nsig
  temparray(5) = real(kl)
  temparray(6) = real(lapsbot)
  temparray(7) = real(isoth)
  temparray(8) = real(nsig)
end if
      
! Broadcast grid data to all processors
! (Since integers are smaller than 1e7, then they can be exactly
!  represented using real*4)
call ccmpi_bcast(temparray(1:8),0,comm_world)
rlong0  = temparray(1)
rlat0   = temparray(2)
schmidt = temparray(3)
il_g    = nint(temparray(4))
kl      = nint(temparray(5))
lapsbot = nint(temparray(6))
isoth   = nint(temparray(7))
nsig    = nint(temparray(8))

      
!--------------------------------------------------------------
! DEFINE newmpar VARIABLES AND DEFAULTS
! CCAM supports face and uniform grid decomposition over processes
! Face decomposition reduces the number of MPI messages, but only works for factors or multiples
! of six processes.  Uniform decomposition is less restrictive on the number of processes, but
! requires a larger number of MPI messages.
call reducenproc(npanels,il_g,nproc,new_nproc,nxp,nyp,uniform_decomp)
call ccmpi_reinit(new_nproc) 

if ( myid<nproc ) then
    
  if ( myid==0 ) then
    write(6,'(a20," running for nproc =",i7)') version,nproc
    if ( using_omp ) then
      write(6,*) 'Using OpenMP with number of threads = ',maxthreads
    end if
    write(6,*) 'Using defaults for nversion = ',nversion
#ifdef usempi3
    write(6,*) 'Using shared memory with number of nodes = ',nodecaptian_nproc
#endif
    write(6,*) 'Reading namelist from ',trim(nmlfile)
    write(6,*) 'ilx,jlx              ',ilx,jlx
    write(6,*) 'rlong0,rlat0,schmidt ',rlong0,rlat0,schmidt
    write(6,*) 'kl,ol                ',kl,ol
    write(6,*) 'lapsbot,isoth,nsig   ',lapsbot,isoth,nsig
    if ( uniform_decomp ) then
      write(6,*) "Using uniform grid decomposition"
    else
      write(6,*) "Using face grid decomposition"
    end if
  end if
  jl_g    = il_g + npanels*il_g                 ! size of grid along all panels (usually 6*il_g)
  ifull_g = il_g*jl_g                           ! total number of global horizontal grid points
  iquad   = 1 + il_g*((8*npanels)/(npanels+4))  ! grid size for interpolation calculations
  il      = il_g/nxp                            ! local grid size on process in X direction
  jl      = jl_g/nyp                            ! local grid size on process in Y direction
  ifull   = il*jl                               ! total number of local horizontal grid points
  ! The perimeter of the processor region has length 2*(il+jl).
  ! The first row has 8 possible corner points per panel and the 
  ! second has 16. In practice these are not all distinct so there could
  ! be some optimisation.
  if ( uniform_decomp ) then
    npan = npanels + 1               ! number of panels on this process
  else
    npan = max(1, (npanels+1)/nproc) ! number of panels on this process
  end if
  iextra = (4*(il+jl)+24)*npan       ! size of halo for MPI message passing
  call ccomp_ntiles
  if ( myid==0 ) then
    write(6,*) "Using ntiles and imax of ",ntiles,ifull/ntiles
  end if  
  ! nrows_rad is a subgrid decomposition for older radiation routines
  nrows_rad = max( min( maxtilesize/il, jl ), 1 ) 
  do while( mod(jl, nrows_rad)/=0 )
    nrows_rad = nrows_rad - 1
  end do
  if ( myid==0 ) then
    write(6,*) "il_g,jl_g,il,jl   ",il_g,jl_g,il,jl
    write(6,*) "nxp,nyp,nrows_rad ",nxp,nyp,nrows_rad
  end if

  ! some default values for unspecified parameters
  if ( ia<0 ) ia = il/2          ! diagnostic point
  if ( ib<0 ) ib = ia + 3        ! diagnostic point
  if ( ldr==0 ) mbase = 0        ! convection
  dsig4 = max(dsig2+.01, dsig4)  ! convection

  ! check nudging settings - adjust mbd scale parameter to satisfy mbd_maxscale and mbd_maxgrid settings
  if ( mbd/=0 .and. nbd/=0 ) then
    if ( myid==0 ) then  
      write(6,*) 'WARN: setting nbd=0 because mbd/=0'
    end if  
    nbd = 0
  end if
  if ( mbd/=0 ) then
    if ( mbd_maxscale==0 ) then
      write(6,*) "ERROR: mbd_maxscale must be >0 when mbd/=0"
      call ccmpi_abort(-1)
    end if
    mbd_min = int(20.*112.*90.*schmidt/real(mbd_maxscale))
    if ( mbd<mbd_min .and. mbd/=0 ) then
      if ( myid==0 ) then
        write(6,*) "Increasing mbd to satisfy mbd_maxscale ",mbd_maxscale
        write(6,*) "Original mbd and final mbd = ",mbd,mbd_min
      end if
      mbd = mbd_min
    end if
    if ( mbd_maxgrid==0 ) then
      write(6,*) "ERROR: mbd_maxgrid must be >0 when mbd/=0"
      call ccmpi_abort(-1)
    end if
    mbd_min = int(20.*real(il_g)/real(mbd_maxgrid))
    if ( mbd<mbd_min .and. mbd/=0 ) then
      if ( myid==0 ) then
        write(6,*) "Adjusting mbd to satisfy mbd_maxgrid = ",mbd_maxgrid
        write(6,*) "Original mbd and final mbd = ",mbd,mbd_min
      end if
      mbd = mbd_min
    end if
    nud_hrs = abs(nud_hrs)  ! just for people with old -ves in namelist
    if ( nudu_hrs==0 ) then
      nudu_hrs = nud_hrs
    end if
  end if
  if ( mbd_mlo/=0 .or. nud_sst/=0 .or. nud_sss/=0 .or. nud_ouv/=0 .or. nud_sfh/=0 ) then
    mbd_mlo = max( nud_sst, nud_sss, nud_ouv, nud_sfh, mbd, mbd_mlo )
  end if
  if ( mbd_mlo/=0 ) then
    if ( mbd_maxscale_mlo==0 ) then
      write(6,*) "ERROR: mbd_maxscale_mlo must be >0 when mbd_mlo/=0"
      call ccmpi_abort(-1)
    end if
    mbd_min = int(20.*112.*90.*schmidt/real(mbd_maxscale_mlo))
    if ( mbd_mlo<mbd_min ) then
      if ( myid==0 ) then
        write(6,*) "Adjusting mbd_mlo to satisfy mbd_maxscale_mlo = ",mbd_maxscale_mlo
        write(6,*) "Original mbd_mlo and final mbd_mlo = ",mbd_mlo,mbd_min
      end if
      mbd_mlo = mbd_min
    end if
  end if
  if ( kblock<0 ) then
    kblock = max(kl, ol) ! must occur before indata
    if ( myid==0 ) then
      write(6,*) "Adjusting kblock to ",kblock
    end if
  end if

  ! **** do namelist fixes above this line ***

  !--------------------------------------------------------------
  ! REMAP MPI PROCESSES

  ! Optimise the MPI process ranks to reduce inter-node message passing
  call ccmpi_remap


  !--------------------------------------------------------------
  ! DISPLAY NAMELIST

  if ( myid==0 ) then   
    write(6,*)'Dynamics options A:'
    write(6,*)'   mex   mfix  mfix_qg   mup    nh    precon' 
    write(6,'(i4,i6,i10,3i7)')mex,mfix,mfix_qg,mup,nh,precon
    write(6,*)'Dynamics options B:'
    write(6,*)'nritch_t ntbar  epsp    epsu   epsf   restol'
    write(6,'(i5,i7,1x,3f8.3,g9.2)')nritch_t,ntbar,epsp,epsu,epsf,restol
    write(6,*)'Dynamics options C:'
    write(6,*)'helmmeth mfix_aero mfix_tr'
    write(6,'(i8,i10,i8)') helmmeth,mfix_aero,mfix_tr
    write(6,*)'Dynamics options D:'
    write(6,*)'epsh'
    write(6,'(f8.3)') epsh
    write(6,*)'Horizontal advection/interpolation options:'
    write(6,*)' nt_adv mh_bs'
    write(6,'(i5,i7)') nt_adv,mh_bs
    write(6,*)'Horizontal wind staggering options:'
    write(6,*)'nstag nstagu'
    write(6,'(2i7)') nstag,nstagu
    write(6,*)'Horizontal mixing options:'
    write(6,*)' khdif  khor   nhor   nhorps nhorjlm'
    write(6,'(i5,11i7)') khdif,khor,nhor,nhorps,nhorjlm
    write(6,*)'Vertical mixing/physics options A:'
    write(6,*)' nvmix nlocal ncvmix  lgwd' 
    write(6,'(i5,6i7)') nvmix,nlocal,ncvmix,lgwd
    write(6,*)'Vertical mixing/physics options B:'
    write(6,*)' be   cm0  ce0  ce1  ce2  ce3  cq'
    write(6,'(7f5.2)') be,cm0,ce0,ce1,ce2,ce3,cq
    write(6,*)'Vertical mixing/physics options C:'
    write(6,*)' ent0  dtrc0   m0    b1    b2'
    write(6,'(5f6.2)') ent0,dtrc0,m0,b1,b2
    write(6,*)'Vertical mixing/physics options D:'
    write(6,*)' buoymeth stabmeth maxdts qcmf'
    write(6,'(2i9,f8.2,g9.2)') buoymeth,stabmeth,maxdts,qcmf
    write(6,*)'Vertical mixing/physics options E:'
    write(6,*)'  mintke   mineps     minl     maxl'
    write(6,'(4g9.2)') mintke,mineps,minl,maxl
    write(6,*)'Vertical mixing/physics options F:'
    write(6,*)'  cgmap_offset   cgmap_scale'
    write(6,'(2f14.2)') cgmap_offset,cgmap_scale  
    write(6,*)'Gravity wave drag options:'
    write(6,*)' ngwd   helim     fc2  sigbot_gwd  alphaj'
    write(6,'(i5,2x,3f8.2,f12.6)') ngwd,helim,fc2,sigbot_gwd,alphaj
    write(6,*)'Cumulus convection options A:'
    write(6,*)' nkuo  sigcb sig_ct  rhcv  rhmois rhsat convfact convtime shaltime'
    write(6,'(i5,6f7.2,3x,9f8.2)') nkuo,sigcb,sig_ct,rhcv,rhmois,rhsat,convfact,convtime,shaltime
    write(6,*)'Cumulus convection options B:'
    write(6,*)' alflnd alfsea fldown iterconv ncvcloud nevapcc nevapls nuvconv'
    write(6,'(3f7.2,i6,i10,4i8)') alflnd,alfsea,fldown,iterconv,ncvcloud,nevapcc,nevapls,nuvconv
    write(6,*)'Cumulus convection options C:'
    write(6,*)' mbase mdelay methprec nbase detrain entrain methdetr detrainx dsig2  dsig4'
    write(6,'(3i6,i9,f8.2,f9.2,i8,4f8.2)') mbase,mdelay,methprec,nbase,detrain,entrain,methdetr,detrainx,dsig2,dsig4
    write(6,*)'Shallow convection options:'
    write(6,*)'  ksc  kscsea kscmom sigkscb sigksct tied_con tied_over tied_rh '
    write(6,'(i5,2i7,1x,3f8.3,2f10.3)') ksc,kscsea,kscmom,sigkscb,sigksct,tied_con,tied_over,tied_rh
    write(6,*)'Other moist physics options:'
    write(6,*)'  acon   bcon   qgmin      rcm    rcrit_l rcrit_s'
    write(6,'(2f7.2,2e10.2,2f7.2)') acon,bcon,qgmin,rcm,rcrit_l,rcrit_s
    write(6,*)'Radiation options A:'
    write(6,*)' nrad  mins_rad iaero  dt'
    write(6,'(i5,2i7,f10.2)') nrad,mins_rad,iaero,dt
    write(6,*)'Radiation options B:'
    write(6,*)' nmr bpyear sw_diff_streams sw_resolution'
    write(6,'(i4,f9.2,i4,a5,i4)') nmr,bpyear,sw_diff_streams,sw_resolution
    write(6,*)'Radiation options C:'
    write(6,*)' liqradmethod iceradmethod carbonradmethod'
    write(6,'(3i4)') liqradmethod,iceradmethod,carbonradmethod
    write(6,*)'Aerosol options:'
    write(6,*)'  iaero ch_dust'
    write(6,'(i7,g9.2,f7.2)') iaero,ch_dust
    write(6,*)'  zvolcemi aeroindir'
    write(6,'(f7.2,i5)') zvolcemi,aeroindir
    write(6,*)'Cloud options A:'
    write(6,*)'  ldr nclddia nstab_cld nrhcrit sigcll '
    write(6,'(i5,i6,2i9,1x,f8.2)') ldr,nclddia,nstab_cld,nrhcrit,sigcll
    write(6,*)'Cloud options B:'
    write(6,*)'  ncloud'
    write(6,'(i5)') ncloud
    write(6,*)'Soil, canopy and PBL options A:'
    write(6,*)' jalbfix nalpha nbarewet newrough nglacier nrungcm nsib  nsigmf'
    write(6,'(i5,9i8)') jalbfix,nalpha,nbarewet,newrough,nglacier,nrungcm,nsib,nsigmf
    write(6,*)'Soil, canopy and PBL options B:'
    write(6,*)' ntaft ntsea ntsur av_vmod tss_sh vmodmin  zobgin charnock chn10'
    write(6,'(i5,2i6,4f8.2,f8.3,f9.5)') ntaft,ntsea,ntsur,av_vmod,tss_sh,vmodmin,zobgin,charnock,chn10
    write(6,*)'Soil, canopy and PBL options C:'
    write(6,*)' nurban ccycle'
    write(6,'(2i7)') nurban,ccycle
    write(6,*)'Ocean/lake options:'
    write(6,*)' nmlo  ol      mxd   mindep minwater  ocnsmag   ocneps'
    write(6,'(i5,i4,5f9.2)') nmlo,ol,mxd,mindep,minwater,ocnsmag,ocneps
    write(6,*)' mlodiff  zomode zoseaice factchseaice otaumode'
    write(6,'(2i8,f9.6,f13.6,i8)') mlodiff,zomode,zoseaice,factchseaice,otaumode
    write(6,*)' nriver rivermd basinmd rivercoeff'
    write(6,'(3i8,g9.2)') nriver,rivermd,basinmd,rivercoeff
    write(6,*)'Nudging options A:'
    write(6,*)' nbd    nud_p  nud_q  nud_t  nud_uv nud_hrs nudu_hrs kbotdav  kbotu'
    write(6,'(i5,3i7,7i8)') nbd,nud_p,nud_q,nud_t,nud_uv,nud_hrs,nudu_hrs,kbotdav,kbotu
    write(6,*)'Nudging options B:'
    write(6,*)' mbd    mbd_maxscale mbd_maxgrid mbd_maxscale_mlo ktopdav kblock'
    write(6,'(i5,2i12,i16,2i8)') mbd,mbd_maxscale,mbd_maxgrid,mbd_maxscale_mlo,ktopdav,kblock
    write(6,*)'Nudging options C:'
    write(6,*)' nud_sst nud_sss nud_ouv nud_sfh ktopmlo kbotmlo mloalpha'
    write(6,'(6i8,i9)') nud_sst,nud_sss,nud_ouv,nud_sfh,ktopmlo,kbotmlo,mloalpha
    write(6,*)'Nudging options D:'
    write(6,*)' sigramplow sigramphigh nud_period'
    write(6,'(2f10.6,i9)') sigramplow,sigramphigh,nud_period
    write(6,*)'Special and test options A:'
    write(6,*)' namip amipo3 newtop nhstest nsemble nspecial panfg panzo'
    write(6,'(1i5,L7,3i7,i8,f9.1,f8.4)') namip,amipo3,newtop,nhstest,nsemble,nspecial,panfg,panzo
    write(6,*)'Special and test options B:'
    write(6,*)' knh rescrn'
    write(6,'(i4,i7)') knh,rescrn
    write(6,*)'I/O options:'
    write(6,*)' m_fly  io_in io_nest io_out io_rest  nwt  nperavg'
    write(6,'(i5,4i7,3i8)') m_fly,io_in,io_nest,io_out,io_rest,nwt,nperavg

    write(6, cardin)
    write(6, skyin)
    write(6, datafile)
    write(6, kuonml)
    write(6, turbnml)
    write(6, landnml)
    write(6, mlonml)
  end if ! myid=0
  if ( nllp==0 .and. nextout>=4 ) then
    write(6,*) 'need nllp=3 for nextout>=4'
    call ccmpi_abort(-1)
  end if
  if ( newtop>2 ) then
    write(6,*) 'newtop>2 no longer allowed'
    call ccmpi_abort(-1)
  end if
  if ( mfix_qg>0 .and. nkuo==4 ) then
    write(6,*) 'nkuo=4: mfix_qg>0 not allowed'
    call ccmpi_abort(-1)
  end if
  nstagin  = nstag    ! -ve nstagin gives swapping & its frequency
  nstaguin = nstagu   ! only the sign of nstaguin matters (chooses scheme)
  if ( nstagin==5 .or. nstagin<0 ) then
    nstag  = 4
    nstagu = 4
    if ( nstagin==5 ) then  ! for backward compatability
      nstagin  = -1 
      nstaguin = 5  
    endif
  endif
  if ( surfile /= ' ' ) then
    if ( tblock<=0 .or. tbave<=0 ) then
      write(6,*) "ERROR: tblock and tbave must be greater than zero"
      write(6,*) "tblock,tbave ",tblock,tbave
      call ccmpi_abort(-1)  
    end if
    if ( mod(ntau, tblock*tbave)/=0 ) then
      write(6,*) "ERROR: tblock*tave must be a factor of ntau"
      write(6,*) "ntau,tblock,tbave ",ntau,tblock,tbave
      call ccmpi_abort(-1)
    end if
  end if
  tke_umin = vmodmin


  !--------------------------------------------------------------
  ! SHARED MEMORY AND FILE IO CONFIGURATION

  ! This is the procformat IO system where a single output file is
  ! written per node
  call ccmpi_procformat_init(procformat,procmode) 
  if ( procformat .and. .not.localhist ) then
    write(6,*) "ERROR: procformat=.true. requires localhist=.true."
    call ccmpi_abort(-1)
  end if


  !--------------------------------------------------------------
  ! INITIALISE ifull_g ALLOCATABLE ARRAYS

#ifdef usempi3
  ! Allocate xx4, yy4, em_g, x_g, y_g and z_g as shared
  ! memory within a node.  The node captian is responsible
  ! for updating these arrays.
  shsize(1:2) = (/ iquad, iquad /)
  call ccmpi_allocshdatar8(xx4,shsize(1:2),xx4_win)
  call ccmpi_allocshdatar8(yy4,shsize(1:2),yy4_win)
  shsize(1) = ifull_g
  call ccmpi_allocshdata(em_g,shsize(1:1),em_g_win)
  call ccmpi_allocshdatar8(x_g,shsize(1:1),x_g_win)
  call ccmpi_allocshdatar8(y_g,shsize(1:1),y_g_win)
  call ccmpi_allocshdatar8(z_g,shsize(1:1),z_g_win)
#else
  ! Allocate xx4, yy4, em_g, x_g, y_g and z_g for each process
  allocate( xx4_dummy(iquad,iquad), yy4_dummy(iquad,iquad) )
  xx4 => xx4_dummy
  yy4 => yy4_dummy
  allocate( em_g_dummy(ifull_g) )
  em_g => em_g_dummy
  allocate( x_g_dummy(ifull_g), y_g_dummy(ifull_g), z_g_dummy(ifull_g) )
  x_g => x_g_dummy
  y_g => y_g_dummy
  z_g => z_g_dummy
#endif
  call xyzinfo_init(ifull_g,ifull,myid)
  call indices_init(ifull,npan)
  call map_init(ifull_g,ifull,iextra,myid)
  call latlong_init(ifull_g,ifull,myid)      
  call vecsuv_init(ifull_g,ifull,iextra,myid)
  call workglob_init(ifull_g,ifull,myid)


  !--------------------------------------------------------------
  ! SET UP CC GEOMETRY

  ! Only one process calls setxyz to save memory with large grids
  if ( myid==0 ) then
    write(6,*) "Calling setxyz"
    call setxyz(il_g,rlong0,rlat0,schmidt,x_g,y_g,z_g,wts_g,ax_g,ay_g,az_g,bx_g,by_g,bz_g,xx4,yy4, &
                id,jd,ktau,ds)
  end if
  ! Broadcast the following global data
  ! xx4 and yy4 are used for calculating depature points
  ! em_g, x_g, y_g and z_g are for the scale-selective filter (1D and 2D versions)
#ifdef usempi3
  ! use shared memory for global arrays common to all processes
  call ccmpi_shepoch(xx4_win)
  if ( node_myid==0 ) call ccmpi_bcastr8(xx4,0,comm_nodecaptian)
  call ccmpi_shepoch(xx4_win)
  call ccmpi_shepoch(yy4_win)
  if ( node_myid==0 ) call ccmpi_bcastr8(yy4,0,comm_nodecaptian)
  call ccmpi_shepoch(yy4_win)
  call ccmpi_shepoch(em_g_win)
  if ( node_myid==0 ) call ccmpi_bcast(em_g,0,comm_nodecaptian)
  call ccmpi_shepoch(em_g_win)
  call ccmpi_shepoch(x_g_win)
  if ( node_myid==0 ) call ccmpi_bcastr8(x_g,0,comm_nodecaptian)
  call ccmpi_shepoch(x_g_win)
  call ccmpi_shepoch(y_g_win)
  if ( node_myid==0 ) call ccmpi_bcastr8(y_g,0,comm_nodecaptian)
  call ccmpi_shepoch(y_g_win)
  call ccmpi_shepoch(z_g_win)
  if ( node_myid==0 ) call ccmpi_bcastr8(z_g,0,comm_nodecaptian)
  call ccmpi_shepoch(z_g_win)
#else
  ! MJT notes - make copies of global arrays on all processes
  call ccmpi_bcastr8(xx4,0,comm_world)
  call ccmpi_bcastr8(yy4,0,comm_world)
  call ccmpi_bcast(em_g,0,comm_world)
  call ccmpi_bcastr8(x_g,0,comm_world)
  call ccmpi_bcastr8(y_g,0,comm_world)
  call ccmpi_bcastr8(z_g,0,comm_world)
#endif
  call ccmpi_bcast(ds,0,comm_world)

  if ( myid==0 ) then
    write(6,*) "Calling ccmpi_setup"
  end if
  call ccmpi_setup(kblock,id,jd,idjd,dt)

      
  !--------------------------------------------------------------
  ! DEALLOCATE ifull_g ARRAYS WHERE POSSIBLE
  if ( myid==0 ) then
    deallocate( wts_g, emu_g, emv_g )
    deallocate( ax_g, ay_g, az_g )
    deallocate( bx_g, by_g, bz_g )
    deallocate( f_g, fu_g, fv_g )
    deallocate( dmdx_g, dmdy_g )
    deallocate( rlatt_g, rlongg_g )
    deallocate( rlong4, rlat4 )
  end if


  !--------------------------------------------------------------
  ! INITIALISE LOCAL ARRAYS
  allocate( dums(ifull,kl) )
  call arrays_init(ifull,iextra,kl)
  call carbpools_init(ifull,nsib,ccycle)
  call cfrac_init(ifull,kl)
  call cloudmod_init(ifull,iextra,kl,ncloud)
  call dpsdt_init(ifull,epsp)
  call epst_init(ifull)
  call estab_init
  call extraout_init(ifull,nextout)
  call gdrag_init(ifull)
  call histave_init(ifull,kl,ms,ccycle)
  call kuocomb_init(ifull,kl)
  call liqwpar_init(ifull,iextra,kl)
  call morepbl_init(ifull)
  call nharrs_init(ifull,iextra,kl)
  call nlin_init(ifull,kl)
  call nsibd_init(ifull,nsib,cable_climate)
  call parmhdff_init(kl)
  call pbl_init(ifull)
  call permsurf_init(ifull)
  call prec_init(ifull)
  call raddiag_init(ifull,kl)
  call riverarrays_init(ifull,iextra,nriver)
  call savuvt_init(ifull,kl)
  call savuv1_init(ifull,kl)
  call sbar_init(ifull,kl)
  call screen_init(ifull)
  call sigs_init(kl)
  call soil_init(ifull,iaero,nsib)
  call soilsnow_init(ifull,ms,nsib)
  call tbar2d_init(ifull)
  call unn_init(ifull,kl)
  call uvbar_init(ifull,kl)
  call vecs_init(kl)
  call vegpar_init(ifull)
  call vvel_init(ifull,kl)
  call work2_init(ifull,nsib)
  call work3_init(ifull,nsib)
  call work3f_init(ifull,kl)
  call xarrs_init(ifull,iextra,kl)
  if ( nvmix==6 ) then
    call tkeinit(ifull,iextra,kl,0)
  end if
  if ( tracerlist/=' ' ) then
    call init_tracer
  end if
  call work3sav_init(ifull,kl,ngas) ! must occur after tracers_init
  if ( nbd/=0 .or. mbd/=0 ) then
    if ( abs(iaero)>=2 .and. nud_aero/=0 ) then
      call dav_init(ifull,kl,naero,nbd,mbd)
    else
      call dav_init(ifull,kl,0,nbd,mbd)
    end if
  end if
  ! Remaining arrays are allocated in indata.f90, since their
  ! definition requires additional input data (e.g, land-surface)

  
  !--------------------------------------------------------------
  ! DISPLAY DIAGNOSTIC INDEX AND TIMER DATA
  if ( mydiag ) then
    write(6,"('id,jd,rlongg,rlatt in degrees: ',2i4,2f8.2)") id,jd,180./pi*rlongg(idjd),180./pi*rlatt(idjd)
  end if
  call date_and_time(rundate)
  call date_and_time(time=timeval)
  if ( myid==0 ) then
    write(6,*)'RUNDATE IS ',rundate
    write(6,*)'Starting time ',timeval
  end if


  !--------------------------------------------------------------
  ! READ INITIAL CONDITIONS
  if ( myid==0 ) then
    write(6,*) "Calling indata"
  end if
  call indataf(lapsbot,isoth,nsig,io_nest)


  !--------------------------------------------------------------
  ! SETUP REMAINING PARAMETERS
  
  ! fix nudging levels from pressure to level index
  ! this is done after indata has loaded sig
  if ( kbotdav<0 ) then
    targetlev = real(-kbotdav)/1000.
    do k = 1,kl
      if ( sig(k)<=targetlev ) then
        kbotdav = k
        if ( myid==0 ) then
          write(6,*) "kbotdav adjusted to ",kbotdav,"for sig ",sig(kbotdav)
        end if
        exit
      end if
    end do
    if ( kbotdav<0 ) then
      write(6,*) "ERROR: Cannot locate nudging level for kbotdav ",kbotdav
      call ccmpi_abort(-1)
    end if
  end if
  if ( ktopdav==0 ) then
    ktopdav = kl
  else if ( ktopdav<0 ) then
    targetlev = real(-ktopdav)/1000.
    do k = kl,1,-1
      if ( sig(k)>=targetlev ) then
        ktopdav = k
        if ( myid == 0 ) then
          write(6,*) "ktopdav adjusted to ",ktopdav,"for sig ",sig(ktopdav)
        end if
        exit
      end if
    end do
    if ( ktopdav<0 ) then
      write(6,*) "ERROR: Cannot locate nudging level for ktopdav ",ktopdav
      call ccmpi_abort(-1)
    end if
  end if
  if ( kbotdav<1 .or. ktopdav>kl .or. kbotdav>ktopdav ) then
    write(6,*) "ERROR: Invalid kbotdav and ktopdav"
    write(6,*) "kbotdav,ktopdav ",kbotdav,ktopdav
    call ccmpi_abort(-1)
  end if
  if ( kbotu==0 ) kbotu = kbotdav

  ! fix ocean nuding levels
  if ( nmlo/=0 ) then
    if ( kbotmlo<0 )  then
      targetlev = real(-kbotmlo)/1000.
      do k = ol,1,-1
        if ( gosig(k)<=targetlev ) then
          kbotmlo = k
          if ( myid==0 ) then
            write(6,*) "kbotmlo adjusted to ",kbotmlo,"for sig ",gosig(kbotmlo)
          end if
          exit
        end if
      end do
      if ( kbotmlo<0 ) then
        write(6,*) "ERROR: Cannot locate nudging level for kbotmlo ",kbotmlo
        call ccmpi_abort(-1)
      end if   
    end if
    if ( ktopmlo<0 ) then
      targetlev = real(-ktopmlo)/1000.
      do k = 1,ol
        if ( gosig(k)>=targetlev ) then
          ktopmlo = k
          if ( myid==0 ) then
            write(6,*) "ktopmlo adjusted to ",ktopmlo,"for sig ",gosig(ktopmlo)
          end if
          exit
        end if
      end do
      if ( ktopmlo<0 ) then
        write(6,*) "ERROR: Cannot locate nudging level for ktopmlo ",ktopmlo
        call ccmpi_abort(-1)
      end if
    end if
    if ( ktopmlo<1 .or. kbotmlo>ol .or. ktopmlo>kbotmlo ) then
      write(6,*) "ERROR: Invalid kbotmlo"
      write(6,*) "kbotmlo,ktopmlo ",kbotmlo,ktopmlo
      call ccmpi_abort(-1)
    end if
  end if  

  ! identify reference level ntbar for temperature
  if ( ntbar==-1 ) then
    ntbar = 1
    do while( sig(ntbar)>0.8 .and. ntbar<kl )
      ntbar = ntbar + 1
    end do
  end if

  ! estimate radiation calling frequency
  if ( mins_rad<0 ) then
    ! automatic estimate for mins_rad
    secs_rad = min(nint((schmidt*112.*90./real(il_g))*8.*60.), nint(real(nwt)*dt), 3600)
    kountr   = max(nint(real(secs_rad)/dt), 1)
    secs_rad = nint(real(kountr)*dt)
    do while ( (mod(3600, secs_rad)/=0 .or. mod(nint(real(nwt)*dt), secs_rad)/=0) .and. kountr>1 )
      kountr = kountr - 1
      secs_rad = nint(real(kountr)*dt)
    end do
  else
    ! user specified mins_rad
    kountr   = nint(real(mins_rad)*60./dt)  ! set default radiation to ~mins_rad m
    secs_rad = nint(real(kountr)*dt)        ! redefine to actual value
  end if
  if ( myid==0 ) then
    write(6,*) "Radiation will use kountr ",kountr," for secs_rad ",secs_rad
  end if
  ! for 6-hourly output of sint_ave etc, want 6*60*60 = N*secs_rad      
  if ( (nrad==4.or.nrad==5) .and. mod(21600,secs_rad)/=0 ) then
    write(6,*) 'ERROR: CCAM would prefer 21600 = N*secs_rad ',secs_rad
    call ccmpi_abort(-1)
  end if

  ! max/min diagnostics      
  if ( nextout>=4 ) call setllp

  if ( nmaxpr<=ntau ) then
    call maxmin(u,' u',ktau,1.,kl)
    call maxmin(v,' v',ktau,1.,kl)
    dums(:,:) = sqrt(u(1:ifull,:)**2+v(1:ifull,:)**2)  ! 3D 
    call maxmin(dums,'sp',ktau,1.,kl)
    call maxmin(t,' t',ktau,1.,kl)
    call maxmin(qg,'qg',ktau,1.e3,kl)
    call maxmin(qfg,'qf',ktau,1.e3,kl)
    call maxmin(qlg,'ql',ktau,1.e3,kl)
    call maxmin(wb,'wb',ktau,1.,ms)
    call maxmin(tggsn,'tS',ktau,1.,3)
    call maxmin(tgg,'tgg',ktau,1.,ms)
    pwatr_l = 0.   ! in mm
    do k = 1,kl
      pwatr_l = pwatr_l - sum(dsig(k)*wts(1:ifull)*(qg(1:ifull,k)+qlg(1:ifull,k)+qfg(1:ifull,k))*ps(1:ifull))
    enddo
    pwatr_l = pwatr_l/grav
    temparray(1) = pwatr_l
    call ccmpi_reduce( temparray(1:1), gtemparray(1:1), "sum", 0, comm_world )
    pwatr = gtemparray(1)
    if ( myid==0 ) write (6,"('pwatr0 ',12f7.3)") pwatr
    if ( ntrac>0 ) then
      do ng = 1,ntrac
        write (text,'("g",i1)')ng
        call maxmin(tr(:,:,ng),text,ktau,1.,kl)
      end do
    end if   ! (ntrac>0)
  end if  

  ! convection
  ! sig(kuocb) occurs for level just BELOW sigcb
  kuocb = 1
  do while( sig(kuocb+1)>=sigcb )
    kuocb = kuocb + 1
  end do
  if ( myid==0 ) write(6,*) 'convective cumulus scheme: kuocb,sigcb = ',kuocb,sigcb

  ! horizontal diffusion 
  if ( khdif==-99 ) then   ! set default khdif appropriate to resolution
    khdif = 5
    if ( myid==0 ) write(6,*) 'Model has chosen khdif =',khdif
  endif
  do k = 1,kl
    hdiff(k) = khdif*0.1
  end do
  if ( khor>0 ) then
    do k = kl+1-khor,kl
      hdiff(k) = 2.*hdiff(k-1)
    end do
  elseif ( khor<0 ) then ! following needed +hdiff() (JLM 29/6/15)
    do k = 1,kl                    ! N.B. usually hdiff(k)=khdif*.1 
      ! increase hdiff between sigma=.15  and sigma=0., 0 to khor
      if ( sig(k)<0.15 ) then
        hdiff(k) = .1*max(1.,(1.-sig(k)/.15)*abs(khor)) + hdiff(k)
      end if
    end do
    if ( myid==0 ) write(6,*)'khor,hdiff: ',khor,hdiff
  end if
  if ( nud_p==0 .and. mfix==0 ) then
    write(6,*) "ERROR: Both nud_p=0 and mfix=0"
    write(6,*) "Model will not conserve mass"
    call ccmpi_abort(-1)
  end if
  if ( nud_q==0 .and. mfix_qg==0 ) then
    write(6,*) "ERROR: Both nud_q=0 and mfix_qg=0"
    write(6,*) "Model will not conserve moisture"
    call ccmpi_abort(-1)
  end if
  if ( nud_aero==0 .and. mfix_aero==0 .and. iaero/=0 ) then
    write(6,*) "ERROR: Both nud_aero=0 and mfix_aero=0"
    write(6,*) "Model will not conserve aerosols"
    call ccmpi_abort(-1)
  end if
  if ( mfix_tr==0 .and. ngas>0 ) then
    write(6,*) "ERROR: mfix_tr=0 and ngas>0"
    write(6,*) "Model will not conserve tracers"
    call ccmpi_abort(-1)
  end if
      

  call printa('zs  ',zs,0,0,ia,ib,ja,jb,0.,.01)
  call printa('tss ',tss,0,0,ia,ib,ja,jb,200.,1.)
  if ( mydiag ) write(6,*)'wb(idjd) ',(wb(idjd,k),k=1,6)
  call printa('wb1   ',wb ,0,1,ia,ib,ja,jb,0.,100.)
  call printa('wb6  ',wb,0,ms,ia,ib,ja,jb,0.,100.)

      
  !--------------------------------------------------------------
  ! NRUN COUNTER
  if ( myid==0 ) then
    open(11, file='nrun.dat',status='unknown')
    if ( nrun==0 ) then
      read(11,*,iostat=ierr) nrun
      nrun = nrun + 1
    end if   ! nrun==0
    write(6,*) 'this is run ',nrun
    rewind 11
    write(11,*) nrun
    write(11,cardin)
    write(11,skyin)
    write(11,datafile)
    write(11,kuonml)
    write(11,turbnml)
    write(11,landnml)
    write(11,mlonml)
    close(11)
  end if

  deallocate( dums )
  
end if ! myid<nproc  

return
end subroutine globpe_init
    
!--------------------------------------------------------------
! PREVIOUS VERSION DEFAULT PARAMETERS
subroutine change_defaults(nversion)

use newmpar_m               ! Grid parameters
use parm_m                  ! Model configuration
use parmdyn_m               ! Dynamics parmaters
use parmhor_m               ! Horizontal advection parameters
use parmhdff_m              ! Horizontal diffusion parameters

implicit none

include 'kuocom.h'          ! Convection parameters

integer, intent(in) :: nversion

if ( nversion < 1510 ) then
  mins_rad = 60
end if
if ( nversion < 907 ) then
  mfix = 1         ! new is 3
  newrough = 2     ! new is 0
  newtop = 0       ! new is 1
  nvmix = 5        ! new is 3
  ksc = 0          ! new is -95
  sig_ct = .8      ! new is 1.
end if
if ( nversion < 904 ) then
  newtop = 1       ! new is 0
  nvmix = 3        ! new is 5
  ksc = -95        ! new is 0
  sig_ct = -.8     ! new is .8
end if
if( nversion < 809 ) then
  nvmix = 5        ! new is 3
  ksc = 0          ! new is -95
  sig_ct = .8      ! new is -.8
end if
if ( nversion < 806 ) then
  nvmix = 3        ! new is 5
  ksc = -95        ! new is 0
  nclddia = 5      ! new is 1
end if
if ( nversion == 803 ) then
  restol = 2.e-7   ! new is 4.e-7
end if
if ( nversion < 803 ) then
  restol = 5.e-7   ! new is 2.e-7
  alflnd = 1.15    ! new is 1.1
  alfsea = 1.05    ! new is 1.1
  entrain = 0.     ! new is .05
  ksc = 0          ! new is -95
endif
if ( nversion == 709 ) then
  ksc = 99
end if
if ( nversion < 709 ) then
  precon = 0       ! new is -2900
  restol = 2.e-7   ! new is 5.e-7
  mbase = 2000     ! new is 101
  mdelay = 0       ! new is -1
  nbase = -2       ! new is -4
  sigkscb = -.2    ! new is .95
  sigksct = .75    ! new is .8
  tied_con = 6.    ! new is 2.
  tied_over = 2.   ! new is 0.
  tied_rh = .99    ! new is .75
end if
if ( nversion < 705 ) then
  nstag = 5        ! new is -10
  nstagu = 5       ! new is -1.
  detrain = .3     ! new is .15
end if
if ( nversion < 704 ) then
  mex = 4          ! new is 30.
  ntsur = 2        ! new is 6
end if
if ( nversion < 703 ) then
  ntbar = 4        ! new is 6
  ntsur = 7        ! new is 2
  vmodmin = 2.     ! new is .2
  nbase = 1        ! new is -2
end if
if ( nversion < 701 ) then
  nbase = 0        ! new is 1
end if
if ( nversion < 608 ) then
  epsp = -20.      ! new is -15.
end if
if ( nversion < 606 ) then
  epsp = 1.1       ! new is -20.
  newrough = 0     ! new is 2
  nstag = -10      ! new is 5
  nstagu = 3       ! new is 5
  ntsur = 6        ! new is 7
  mbase = 10       ! new is 2000
end if
if ( nversion < 604 ) then
  mh_bs = 3        ! new is 4
end if
if ( nversion < 602 ) then
  ntbar = 9        ! new is 4
end if
if ( nversion < 601 ) then
  epsp = 1.2       ! new is 1.1
  newrough = 2     ! new is 0
  restol = 1.e-6   ! new is 2.e-7
end if
if ( nversion < 511 ) then
  nstag = 3        ! new is -10
  mins_rad = 120   ! new is 72
  detrain = .1     ! new is .3
  mbase = 1        ! new is 10
  nuvconv = 5      ! new is 0
  sigcb = .97      ! new is 1.
end if
if ( nversion < 510 ) then
  epsp = .1        ! new is 1.2
  epsu = .1        ! new is 0.
  khdif = 5        ! new is 2
  khor = 0         ! new is -8
  nbarewet = 7     ! new is 0
  newrough = 0     ! new is 2
  nhor = 0         ! new is -157
  nhorps = 1       ! new is -1
  nlocal = 5       ! new is 6
  ntsur = 7        ! new is 6
  jalbfix = 0      ! new is 1
  tss_sh = 0.      ! new is 1.
  zobgin = .05     ! new is .02
  detrain = .4     ! new is .1
  convtime = .3    ! new is .33
  iterconv = 2     ! new is 3
  mbase = 0        ! new is 1
  sigcb = 1.       ! new is .97
  sigkscb = .98    ! new is -2.
  tied_rh = .75    ! new is .99
  ldr = 2          ! new is 1
  rcm = 1.e-5      ! new is .92e-5
end if
if ( nversion < 509 ) then
  ntsur = 6        ! new is 7
end if
if ( nversion < 508 ) then
  mh_bs = 1        ! new is 3
  nvmix = 4        ! new is 3
  entrain = .3     ! new is 0.
endif
if ( nversion < 506 ) then
  mh_bs = 4        ! new is 1
end if
if ( nversion < 503 ) then
  ntsur = 5        ! new is 6
end if
if ( nversion < 411 ) then
  nstag = -3       ! new is 3
  nstagu = -3      ! new is 3
  nhor = 155       ! new is 0
  nlocal = 1       ! new is 5
  ngwd = 0         ! new is -5
  nevapls = 5      ! new is -4
  nuvconv = 0      ! new is 5
  detrain = .05    ! new is .4
  entrain = 0.     ! new is .3
  detrainx = 1.    ! new is 0.
  dsig2 = .1       ! new is .15
  dsig4 = .55      ! new is .4
  kscmom = 0       ! new is 1
  ldr = 1          ! new is 2
  nbarewet = 2     ! new is 7
  av_vmod = 1.     ! new is .7
  chn10 = .00137   ! new is .00125
end if

return
end subroutine change_defaults

!--------------------------------------------------------------
! Find valid nproc
subroutine reducenproc(npanels,il_g,nproc,newnproc,nxp,nyp,uniform_test)

use cc_mpi                                 ! CC MPI routines

implicit none

integer, intent(in) :: il_g, nproc, npanels
integer, intent(out) :: newnproc, nxp, nyp
integer nproc_low, nxp_test, nyp_test
logical, intent(out) :: uniform_test

uniform_test = .false.
do nproc_low = nproc,1,-1
  call proctest_face(npanels,il_g,nproc_low,nxp_test,nyp_test)
  if ( nxp_test>0 ) exit
end do
newnproc = nproc_low
nxp = nxp_test
nyp = nyp_test

do nproc_low = nproc,1,-1
  call proctest_uniform(npanels,il_g,nproc_low,nxp_test,nyp_test)
  if ( nxp_test>0 ) exit
end do
if ( nproc_low>newnproc ) then
  uniform_test = .true.
  newnproc = nproc_low
  nxp = nxp_test
  nyp = nyp_test
end if

return
end subroutine reducenproc

!--------------------------------------------------------------
! TEST GRID DECOMPOSITION - FACE   
subroutine proctest_face(npanels,il_g,nproc,nxp,nyp)

implicit none

integer, intent(in) :: il_g, nproc, npanels
integer, intent(out) :: nxp, nyp
integer jl_g

if ( mod(nproc,6)/=0 .and. mod(6,nproc)/=0 ) then
  nxp = -1
else
  jl_g = il_g + npanels*il_g                 ! size of grid along all panels (usually 6*il_g)
  nxp = max( 1, nint(sqrt(real(nproc)/6.)) ) ! number of processes in X direction
  nyp = nproc/nxp                            ! number of processes in Y direction
  ! search for valid process decomposition.  CCAM enforces the same grid size on each process
  do while ( (mod(il_g,max(nxp,1))/=0.or.mod(nproc/6,max(nxp,1))/=0.or.mod(jl_g,max(nyp,1))/=0) .and. nxp>0 )
    nxp = nxp - 1
    nyp = nproc/max(nxp,1)
  end do
end if

return
end subroutine proctest_face
    
!--------------------------------------------------------------
! TEST GRID DECOMPOSITION - UNIFORM
subroutine proctest_uniform(npanels,il_g,nproc,nxp,nyp)

implicit none

integer, intent(in) :: il_g, nproc, npanels
integer, intent(out) :: nxp, nyp
integer jl_g

jl_g = il_g + npanels*il_g     ! size of grid along all panels (usually 6*il_g)
nxp = nint(sqrt(real(nproc)))  ! number of processes in X direction
nyp = nproc/nxp                ! number of processes in Y direction
! search for vaild process decomposition.  CCAM enforces the same grid size on each process
do while ( (mod(il_g,max(nxp,1))/=0.or.mod(nproc,max(nxp,1))/=0.or.mod(il_g,nyp)/=0) .and. nxp>0 )
  nxp = nxp - 1
  nyp = nproc/max(nxp,1)
end do

return
end subroutine proctest_uniform
    
!--------------------------------------------------------------------
! Fix water vapour mixing ratio
subroutine fixqg(js,je)

use arrays_m                          ! Atmosphere dyamics prognostic arrays
use const_phys                        ! Physical constants
use liqwpar_m                         ! Cloud water mixing ratios
use newmpar_m                         ! Grid parameters
use parm_m                            ! Model configuration

implicit none

integer, intent(in) :: js, je
integer k
real, dimension(js:je) :: dumqtot, dumliq

if ( js<1 .or. je>ifull ) then
  write(6,*) "ERROR: Invalid index for fixqg"
  stop
end if

do k = 1,kl
  dumqtot(js:je) = qg(js:je,k) + qlg(js:je,k) + qfg(js:je,k) ! qtot
  dumqtot(js:je) = max( dumqtot(js:je), qgmin )
  dumliq(js:je)  = t(js:je,k) - hlcp*qlg(js:je,k) - hlscp*qfg(js:je,k)
  qfg(js:je,k)   = max( qfg(js:je,k), 0. ) 
  qlg(js:je,k)   = max( qlg(js:je,k), 0. )
  qrg(js:je,k)   = max( qrg(js:je,k), 0. )
  qsng(js:je,k)  = max( qsng(js:je,k), 0. )
  qgrg(js:je,k)  = max( qgrg(js:je,k), 0. )
  qg(js:je,k)    = dumqtot(js:je) - qlg(js:je,k) - qfg(js:je,k)
  qg(js:je,k)    = max( qg(js:je,k), 0. )
  t(js:je,k)     = dumliq(js:je) + hlcp*qlg(js:je,k) + hlscp*qfg(js:je,k)
end do

return
end subroutine fixqg

!--------------------------------------------------------------
! Reset diagnostics for averaging period    
subroutine zero_nperavg

use aerosolldr, only :                   & ! LDR prognostic aerosols
     duste,dustwd,dustdd,dust_burden     &
    ,bce,bcwd,bcdd,bc_burden             &
    ,oce,ocwd,ocdd,oc_burden             &
    ,dmse,dms_burden                     &
    ,so2e,so2wd,so2dd,so2_burden         &
    ,so4e,so4wd,so4dd,so4_burden         &
    ,dmsso2o,so2so4o
use cable_ccam, only : ccycle              ! CABLE
use histave_m                              ! Time average arrays
use morepbl_m                              ! Additional boundary layer diagnostics
use parm_m                                 ! Model configuration
use prec_m                                 ! Precipitation
use raddiag_m                              ! Radiation diagnostic
use soilsnow_m                             ! Soil, snow and surface data
use tracers_m                              ! Tracer data

implicit none

convh_ave(:,:)       = 0.
cbas_ave(:)          = 0.
ctop_ave(:)          = 0.
dew_ave(:)           = 0.
epan_ave(:)          = 0.
epot_ave(:)          = 0.
eg_ave(:)            = 0.
fg_ave(:)            = 0.
ga_ave(:)            = 0.
anthropogenic_ave(:) = 0.
tasurban_ave(:)      = 0.
tmaxurban(:)         = urban_tas
tminurban(:)         = urban_tas
rnet_ave(:)          = 0.
sunhours(:)          = 0.
riwp_ave(:)          = 0.
rlwp_ave(:)          = 0.
qscrn_ave(:)         = 0.
tscr_ave(:)          = 0.
wb_ave(:,:)          = 0.
wbice_ave(:,:)       = 0.
tsu_ave(:)           = 0.
alb_ave(:)           = 0.
fbeam_ave(:)         = 0.
psl_ave(:)           = 0.
mixdep_ave(:)        = 0.

! radiation
koundiag             = 0
sint_ave(:)          = 0.
sot_ave(:)           = 0.
soc_ave(:)           = 0.
sgdn_ave(:)          = 0.
sgn_ave(:)           = 0.
rtu_ave(:)           = 0.
rtc_ave(:)           = 0.
rgdn_ave(:)          = 0.
rgn_ave(:)           = 0.
rgc_ave(:)           = 0.
sgc_ave(:)           = 0.
cld_ave(:)           = 0.
cll_ave(:)           = 0.
clm_ave(:)           = 0.
clh_ave(:)           = 0.

! zero evap, precip, precc, sno, runoff fields each nperavg (3/12/04) 
evap(:)              = 0.  
precip(:)            = 0.  ! converted to mm/day in outcdf
precc(:)             = 0.  ! converted to mm/day in outcdf
sno(:)               = 0.  ! converted to mm/day in outcdf
grpl(:)              = 0.  ! converted to mm/day in outcdf
runoff(:)            = 0.  ! converted to mm/day in outcdf
runoff_surface(:)    = 0.  ! converted to mm/day in outcdf
snowmelt(:)          = 0.  ! converted to mm/day in outcdf
u10mx(:)             = 0.
cape_max(:)          = 0.
cape_ave(:)          = 0.

if ( ngas>0 ) then
  traver = 0.
end if

if ( ccycle/=0 ) then
  fnee_ave = 0.  
  fpn_ave  = 0.
  frd_ave  = 0.
  frp_ave  = 0.
  frpw_ave = 0.
  frpr_ave = 0.
  frs_ave  = 0.
  cnpp_ave = 0.
  cnbp_ave = 0.
end if

if ( abs(iaero)>=2 ) then
  duste         = 0.  ! Dust emissions
  dustdd        = 0.  ! Dust dry deposition
  dustwd        = 0.  ! Dust wet deposition
  dust_burden   = 0.  ! Dust burden
  bce           = 0.  ! Black carbon emissions
  bcdd          = 0.  ! Black carbon dry deposition
  bcwd          = 0.  ! Black carbon wet deposition
  bc_burden     = 0.  ! Black carbon burden
  oce           = 0.  ! Organic carbon emissions
  ocdd          = 0.  ! Organic carbon dry deposition
  ocwd          = 0.  ! Organic carbon wet deposition
  oc_burden     = 0.  ! Organic carbon burden
  dmse          = 0.  ! DMS emissions
  dmsso2o       = 0.  ! DMS -> SO2 oxidation
  so2e          = 0.  ! SO2 emissions
  so2so4o       = 0.  ! SO2 -> SO4 oxidation
  so2dd         = 0.  ! SO2 dry deposition
  so2wd         = 0.  ! SO2 wet deposiion
  so4e          = 0.  ! SO4 emissions
  so4dd         = 0.  ! SO4 dry deposition
  so4wd         = 0.  ! SO4 wet deposition
  dms_burden    = 0.  ! DMS burden
  so2_burden    = 0.  ! SO2 burden
  so4_burden    = 0.  ! SO4 burden
end if

return
end subroutine zero_nperavg
    
!--------------------------------------------------------------
! Reset diagnostics for daily averages    
subroutine zero_nperday

use histave_m                              ! Time average arrays
use parm_m                                 ! Model configuration
use prec_m                                 ! Precipitation
use screen_m                               ! Screen level diagnostics

implicit none

rndmax (:)  = 0.
tmaxscr(:)  = tscrn(:) 
tminscr(:)  = tscrn(:) 
rhmaxscr(:) = rhscrn(:) 
rhminscr(:) = rhscrn(:) 
u10max(:)   = 0.
v10max(:)   = 0.
u1max(:)    = 0.
v1max(:)    = 0.
u2max(:)    = 0.
v2max(:)    = 0.
rnd_3hr(:,8)= 0.       ! i.e. rnd24(:)=0.

if ( nextout >= 4 ) then
  call setllp ! reset once per day
end if

return
end subroutine zero_nperday
    
!--------------------------------------------------------------
! Update diagnostics for averaging period    
subroutine calculate_timeaverage

use aerosolldr, only :                   & ! LDR prognostic aerosols
     duste,dustwd,dustdd,dust_burden     &
    ,bce,bcwd,bcdd,bc_burden             &
    ,oce,ocwd,ocdd,oc_burden             &
    ,dmse,dms_burden                     &
    ,so2e,so2wd,so2dd,so2_burden         &
    ,so4e,so4wd,so4dd,so4_burden         &
    ,dmsso2o,so2so4o
use arrays_m                               ! Atmosphere dyamics prognostic arrays
use cable_ccam, only : ccycle              ! CABLE
use carbpools_m, only : fnee,fpn,frd,frp & ! Carbon pools
    ,frpw,frpr,frs,cnpp,cnbp
use histave_m                              ! Time average arrays
use mlo, only : mlodiag                    ! Ocean physics and prognostic arrays
use morepbl_m                              ! Additional boundary layer diagnostics
use newmpar_m                              ! Grid parameters
use outcdf                                 ! Output file routines
use parm_m                                 ! Model configuration
use pbl_m                                  ! Boundary layer arrays
use prec_m                                 ! Precipitation
use raddiag_m                              ! Radiation diagnostic
use screen_m                               ! Screen level diagnostics
use soilsnow_m                             ! Soil, snow and surface data
use tracers_m                              ! Tracer data
use work3_m                                ! Mk3 land-surface diagnostic arrays

implicit none

integer iq, k
real, dimension(ifull) :: spare1, spare2

tmaxscr(1:ifull)           = max( tmaxscr(1:ifull), tscrn )
tminscr(1:ifull)           = min( tminscr(1:ifull), tscrn )
rhmaxscr(1:ifull)          = max( rhmaxscr(1:ifull), rhscrn )
rhminscr(1:ifull)          = min( rhminscr(1:ifull), rhscrn )
rndmax(1:ifull)            = max( rndmax(1:ifull), condx )
cape_max(1:ifull)          = max( cape_max(1:ifull), cape )
cape_ave(1:ifull)          = cape_ave(1:ifull) + cape
u10mx(1:ifull)             = max( u10mx(1:ifull), u10 )  ! for hourly scrnfile
dew_ave(1:ifull)           = dew_ave(1:ifull) - min( 0., eg )    
epan_ave(1:ifull)          = epan_ave(1:ifull) + epan
epot_ave(1:ifull)          = epot_ave(1:ifull) + epot 
eg_ave(1:ifull)            = eg_ave(1:ifull) + eg    
fg_ave(1:ifull)            = fg_ave(1:ifull) + fg
ga_ave(1:ifull)            = ga_ave(1:ifull) + ga
anthropogenic_ave(1:ifull) = anthropogenic_ave(1:ifull) + anthropogenic_flux
tasurban_ave(1:ifull)      = tasurban_ave(1:ifull) + urban_tas
tmaxurban(1:ifull)         = max( tmaxurban(1:ifull), urban_tas )
tminurban(1:ifull)         = min( tminurban(1:ifull), urban_tas )
rnet_ave(1:ifull)          = rnet_ave(1:ifull) + rnet
tscr_ave(1:ifull)          = tscr_ave(1:ifull) + tscrn 
qscrn_ave(1:ifull)         = qscrn_ave(1:ifull) + qgscrn 
wb_ave(1:ifull,1:ms)       = wb_ave(1:ifull,1:ms) + wb
wbice_ave(1:ifull,1:ms)    = wbice_ave(1:ifull,1:ms) + wbice
tsu_ave(1:ifull)           = tsu_ave(1:ifull) + tss
call mslp(spare2,psl,zs,t) ! calculate MSLP from psl
spare2 = spare2/100.       ! convert MSLP to hPa
psl_ave(1:ifull)           = psl_ave(1:ifull) + spare2(1:ifull)
spare1(1:ifull)            = 0.
call mlodiag(spare1,0)     ! obtain ocean mixed level depth
mixdep_ave(1:ifull)        = mixdep_ave(1:ifull) + spare1(1:ifull)
spare1(:) = u(1:ifull,1)**2 + v(1:ifull,1)**2
spare2(:) = u(1:ifull,2)**2 + v(1:ifull,2)**2
do iq = 1,ifull
  if ( u10(iq)**2 > u10max(iq)**2 +v10max(iq)**2 ) then
    u10max(iq) = u10(iq)*u(iq,1)/max(.001,sqrt(spare1(iq)))
    v10max(iq) = u10(iq)*v(iq,1)/max(.001,sqrt(spare1(iq)))
  end if
  if ( spare1(iq) > u1max(iq)**2+v1max(iq)**2 ) then
    u1max(iq) = u(iq,1)
    v1max(iq) = v(iq,1)
  end if
  if ( spare2(iq) > u2max(iq)**2+v2max(iq)**2 ) then
    u2max(iq) = u(iq,2)
    v2max(iq) = v(iq,2)
  end if
end do

if ( ngas>0 ) then
  traver(:,:,1:ngas) = traver(:,:,1:ngas) + tr(:,:,1:ngas)
end if

if ( ccycle/=0 ) then
  fnee_ave(1:ifull) = fnee_ave(1:ifull) + fnee  
  fpn_ave(1:ifull)  = fpn_ave(1:ifull) + fpn
  frd_ave(1:ifull)  = frd_ave(1:ifull) + frd
  frp_ave(1:ifull)  = frp_ave(1:ifull) + frp
  frpw_ave(1:ifull) = frpw_ave(1:ifull) + frpw
  frpr_ave(1:ifull) = frpr_ave(1:ifull) + frpr
  frs_ave(1:ifull)  = frs_ave(1:ifull) + frs
  cnpp_ave(1:ifull) = cnpp_ave(1:ifull) + cnpp
  cnbp_ave(1:ifull) = cnbp_ave(1:ifull) + cnbp
end if

if ( ktau==ntau .or. mod(ktau,nperavg)==0 ) then
  cape_ave(1:ifull)          = cape_ave(1:ifull)/min(ntau,nperavg)
  dew_ave(1:ifull)           = dew_ave(1:ifull)/min(ntau,nperavg)
  epan_ave(1:ifull)          = epan_ave(1:ifull)/min(ntau,nperavg)
  epot_ave(1:ifull)          = epot_ave(1:ifull)/min(ntau,nperavg)
  eg_ave(1:ifull)            = eg_ave(1:ifull)/min(ntau,nperavg)
  fg_ave(1:ifull)            = fg_ave(1:ifull)/min(ntau,nperavg)
  ga_ave(1:ifull)            = ga_ave(1:ifull)/min(ntau,nperavg)   
  anthropogenic_ave(1:ifull) = anthropogenic_ave(1:ifull)/min(ntau,nperavg)
  tasurban_ave(1:ifull)      = tasurban_ave(1:ifull)/min(ntau,nperavg)
  rnet_ave(1:ifull)          = rnet_ave(1:ifull)/min(ntau,nperavg)
  sunhours(1:ifull)          = sunhours(1:ifull)/min(ntau,nperavg)
  riwp_ave(1:ifull)          = riwp_ave(1:ifull)/min(ntau,nperavg)
  rlwp_ave(1:ifull)          = rlwp_ave(1:ifull)/min(ntau,nperavg)
  tscr_ave(1:ifull)          = tscr_ave(1:ifull)/min(ntau,nperavg)
  qscrn_ave(1:ifull)         = qscrn_ave(1:ifull)/min(ntau,nperavg)
  do k = 1,ms
    wb_ave(1:ifull,k)    = wb_ave(1:ifull,k)/min(ntau,nperavg)
    wbice_ave(1:ifull,k) = wbice_ave(1:ifull,k)/min(ntau,nperavg)
  end do
  tsu_ave(1:ifull)    = tsu_ave(1:ifull)/min(ntau,nperavg)
  psl_ave(1:ifull)    = psl_ave(1:ifull)/min(ntau,nperavg)
  mixdep_ave(1:ifull) = mixdep_ave(1:ifull)/min(ntau,nperavg)
  sgn_ave(1:ifull)    = sgn_ave(1:ifull)/min(ntau,nperavg)  ! Dec07 because of solar fit
  sgdn_ave(1:ifull)   = sgdn_ave(1:ifull)/min(ntau,nperavg) ! because of solar fit
  sint_ave(1:ifull)   = sint_ave(1:ifull)/max(koundiag,1)
  sot_ave(1:ifull)    = sot_ave(1:ifull)/max(koundiag,1)
  soc_ave(1:ifull)    = soc_ave(1:ifull)/max(koundiag,1)
  rtu_ave(1:ifull)    = rtu_ave(1:ifull)/max(koundiag,1)
  rtc_ave(1:ifull)    = rtc_ave(1:ifull)/max(koundiag,1)
  rgdn_ave(1:ifull)   = rgdn_ave(1:ifull)/max(koundiag,1)
  rgn_ave(1:ifull)    = rgn_ave(1:ifull)/max(koundiag,1)
  rgc_ave(1:ifull)    = rgc_ave(1:ifull)/max(koundiag,1)
  sgc_ave(1:ifull)    = sgc_ave(1:ifull)/max(koundiag,1)
  cld_ave(1:ifull)    = cld_ave(1:ifull)/max(koundiag,1)
  cll_ave(1:ifull)    = cll_ave(1:ifull)/max(koundiag,1)
  clm_ave(1:ifull)    = clm_ave(1:ifull)/max(koundiag,1)
  clh_ave(1:ifull)    = clh_ave(1:ifull)/max(koundiag,1)
  alb_ave(1:ifull)    = alb_ave(1:ifull)/max(koundiag,1)
  fbeam_ave(1:ifull)  = fbeam_ave(1:ifull)/max(koundiag,1)
  cbas_ave(1:ifull)   = 1.1 - cbas_ave(1:ifull)/max(1.e-4,precc(:))  ! 1.1 for no precc
  ctop_ave(1:ifull)   = 1.1 - ctop_ave(1:ifull)/max(1.e-4,precc(:))  ! 1.1 for no precc
 
  if ( ngas>0 ) then
    traver(1:ifull,1:kl,1:ngas) = traver(1:ifull,1:kl,1:ngas)/min(ntau,nperavg)
  end if

  if ( ccycle/=0 ) then
    fnee_ave(1:ifull)   = fnee_ave(1:ifull)/min(ntau,nperavg)  
    fpn_ave(1:ifull)    = fpn_ave(1:ifull)/min(ntau,nperavg)
    frd_ave(1:ifull)    = frd_ave(1:ifull)/min(ntau,nperavg)
    frp_ave(1:ifull)    = frp_ave(1:ifull)/min(ntau,nperavg)
    frpw_ave(1:ifull)   = frpw_ave(1:ifull)/min(ntau,nperavg)
    frpr_ave(1:ifull)   = frpr_ave(1:ifull)/min(ntau,nperavg)
    frs_ave(1:ifull)    = frs_ave(1:ifull)/min(ntau,nperavg)
    cnpp_ave(1:ifull)   = cnpp_ave(1:ifull)/min(ntau,nperavg)
    cnbp_ave(1:ifull)   = cnbp_ave(1:ifull)/min(ntau,nperavg)
  end if
   
  if ( abs(iaero)>=2 ) then
    duste         = duste/min(ntau,nperavg)        ! Dust emissions
    dustdd        = dustdd/min(ntau,nperavg)       ! Dust dry deposition
    dustwd        = dustwd/min(ntau,nperavg)       ! Dust wet deposition
    dust_burden   = dust_burden/min(ntau,nperavg)  ! Dust burden
    bce           = bce/min(ntau,nperavg)          ! Black carbon emissions
    bcdd          = bcdd/min(ntau,nperavg)         ! Black carbon dry deposition
    bcwd          = bcwd/min(ntau,nperavg)         ! Black carbon wet deposition
    bc_burden     = bc_burden/min(ntau,nperavg)    ! Black carbon burden
    oce           = oce/min(ntau,nperavg)          ! Organic carbon emissions
    ocdd          = ocdd/min(ntau,nperavg)         ! Organic carbon dry deposition
    ocwd          = ocwd/min(ntau,nperavg)         ! Organic carbon wet deposition
    oc_burden     = oc_burden/min(ntau,nperavg)    ! Organic carbon burden
    dmse          = dmse/min(ntau,nperavg)         ! DMS emissions
    dmsso2o       = dmsso2o/min(ntau,nperavg)      ! DMS -> SO2 oxidation
    so2e          = so2e/min(ntau,nperavg)         ! SO2 emissions
    so2so4o       = so2so4o/min(ntau,nperavg)      ! SO2 -> SO4 oxidation
    so2dd         = so2dd/min(ntau,nperavg)        ! SO2 dry deposition
    so2wd         = so2wd/min(ntau,nperavg)        ! SO2 wet deposiion
    so4e          = so4e/min(ntau,nperavg)         ! SO4 emissions
    so4dd         = so4dd/min(ntau,nperavg)        ! SO4 dry deposition
    so4wd         = so4wd/min(ntau,nperavg)        ! SO4 wet deposition
    dms_burden    = dms_burden/min(ntau,nperavg)   ! DMS burden
    so2_burden    = so2_burden/min(ntau,nperavg)   ! SO2 burden
    so4_burden    = so4_burden/min(ntau,nperavg)   ! SO4 burden
  end if

end if    ! (ktau==ntau.or.mod(ktau,nperavg)==0)

return
end subroutine calculate_timeaverage

!--------------------------------------------------------------
! output diagnostics to log file    
subroutine write_diagnostics(mins_gmt,nmaxprsav)

use arrays_m                               ! Atmosphere dyamics prognostic arrays
use cc_mpi                                 ! CC MPI routines
use cfrac_m                                ! Cloud fraction
use const_phys                             ! Physical constants
use dates_m                                ! Date data
use diag_m                                 ! Diagnostic routines
use estab                                  ! Liquid saturation function
use extraout_m                             ! Additional diagnostics
use histave_m                              ! Time average arrays
use kuocomb_m                              ! JLM convection
use liqwpar_m                              ! Cloud water mixing ratios
use morepbl_m                              ! Additional boundary layer diagnostics
use newmpar_m                              ! Grid parameters
use nsibd_m                                ! Land-surface arrays
use parm_m                                 ! Model configuration
use pbl_m                                  ! Boundary layer arrays
use prec_m                                 ! Precipitation
use screen_m                               ! Screen level diagnostics
use sigs_m                                 ! Atmosphere sigma levels
use soil_m                                 ! Soil and surface data
use soilsnow_m                             ! Soil, snow and surface data
use tracers_m                              ! Tracer data
use vegpar_m                               ! Vegetation arrays
use vvel_m                                 ! Additional vertical velocity
use work2_m                                ! Diagnostic arrays
use work3_m                                ! Mk3 land-surface diagnostic arrays
use xyzinfo_m                              ! Grid coordinate arrays

implicit none

integer, intent(in) :: mins_gmt, nmaxprsav
integer iq, k, isoil
real, dimension(ifull,kl) :: dums
real, dimension(kl) :: spmean
real, dimension(9) :: temparray, gtemparray
real qtot, pwater, es, psavge, spavge, pslavge
real preccavge, precavge, gke, clhav, cllav
real clmav, cltav

if ( mod(ktau,nmaxpr)==0 .and. mydiag ) then
  write(6,*)
  write (6,"('ktau =',i5,' gmt(h,m):',f6.2,i5,' runtime(h,m):',f7.2,i6)") ktau,timeg,mins_gmt,timer,mtimer
  ! some surface (or point) diagnostics
  isoil = isoilm(idjd)
  write(6,*) 'land,isoil,ivegt,isflag ',land(idjd),isoil,ivegt(idjd),isflag(idjd)
  write (6,"('snage,snowd,alb   ',f8.4,2f8.2)") snage(idjd),snowd(idjd),albvisnir(idjd,1)
  write (6,"('sicedep,fracice,runoff ',3f8.2)") sicedep(idjd),fracice(idjd),runoff(idjd)
  write (6,"('tgg(1-6)   ',9f8.2)") (tgg(idjd,k),k=1,6)
  write (6,"('tggsn(1-3) ',9f8.2)") (tggsn(idjd,k),k=1,3)
  write (6,"('wb(1-6)    ',9f8.3)") (wb(idjd,k),k=1,6)
  write (6,"('wbice(1-6) ',9f8.3)") (wbice(idjd,k),k=1,6)
  write (6,"('smass(1-3) ',9f8.2)") (smass(idjd,k),k=1,3) ! as mm of water
  write (6,"('ssdn(1-3)  ',9f8.2)") (ssdn(idjd,k),k=1,3)
  iq = idjd
  pwater = 0.   ! in mm
  do k = 1,kl
    qtot   = qg(iq,k)+qlg(iq,k)+qfg(iq,k)
    pwater = pwater-dsig(k)*qtot*ps(iq)/grav
  enddo
  write (6,"('pwater,condc,condx,rndmax,rmc',9f8.3)") pwater,condc(idjd),condx(idjd),rndmax(idjd),cansto(idjd)
  write (6,"('wetfac,sno,evap,precc,precip',6f8.2)") wetfac(idjd),sno(idjd),evap(idjd),precc(idjd),precip(idjd)
  write (6,"('tmin,tmax,tscr,tss,tpan',9f8.2)") tminscr(idjd),tmaxscr(idjd),tscrn(idjd),tss(idjd),tpan(idjd)
  write (6,"('u10,ustar,pblh',9f8.2)") u10(idjd),ustar(idjd),pblh(idjd)
  write (6,"('ps,qgscrn',5f8.2,f8.3)") .01*ps(idjd),1000.*qgscrn(idjd)
  write (6,"('dew_,eg_,epot,epan,eg,fg,ga',9f8.2)") dew_ave(idjd),eg_ave(idjd),epot(idjd),epan(idjd),eg(idjd),fg(idjd),ga(idjd)
  write (6,"('zo,cduv',2f8.5)") zo(idjd),cduv(idjd)/vmod(idjd)
  write (6,"('slwa,sint,sg,rt,rg    ',9f8.2)") slwa(idjd),sintsave(idjd),sgsave(idjd),rtsave(idjd),rgsave(idjd)
  write (6,"('cll,clm,clh,clt ',9f8.2)") cloudlo(idjd),cloudmi(idjd),cloudhi(idjd),cloudtot(idjd)
  write (6,"('u10max,v10max,rhmin,rhmax   ',9f8.2)") u10max(iq),v10max(iq),rhminscr(iq),rhmaxscr(iq)
  write (6,"('kbsav,ktsav,convpsav ',2i3,f8.4,9f8.2)") kbsav(idjd),ktsav(idjd),convpsav(idjd)
  spmean(:) = t(idjd,:)
  write (6,"('t   ',9f8.3/4x,9f8.3)") spmean(:)
  spmean(:) = u(idjd,:)
  write (6,"('u   ',9f8.3/4x,9f8.3)") spmean(:)
  spmean(:) = v(idjd,:)
  write (6,"('v   ',9f8.3/4x,9f8.3)") spmean(:)
  spmean(:) = qg(idjd,:)
  write (6,"('qg  ',9f8.3/4x,9f8.3)") spmean(:)
  spmean(:) = qfg(idjd,:)
  write (6,"('qf  ',9f8.3/4x,9f8.3)") spmean(:)
  spmean(:) = qlg(idjd,:)
  write (6,"('ql  ',9f8.3/4x,9f8.3)") spmean(:)
  spmean(:) = cfrac(idjd,:)
  write (6,"('cfrac',9f8.3/5x,9f8.3)") spmean(:)
  do k = 1,kl
    es        = establ(t(idjd,k))
    spmean(k) = 100.*qg(idjd,k)*max(ps(idjd)*sig(k)-es,1.)/(.622*es) ! max as for convjlm
  enddo
  write (6,"('rh  ',9f8.3/4x,9f8.3)") spmean(:)
  spmean(:) = ps(idjd)*dpsldt(idjd,:)
  write (6,"('omgf ',9f8.3/5x,9f8.3)") spmean(:) ! in Pa/s
  write (6,"('sdot ',9f8.3/5x,9f8.3)") sdot(idjd,1:kl)
  if ( nextout >= 4 ) then
    write (6,"('xlat,long,pres ',3f8.2)") tr(idjd,nlv,ngas+1),tr(idjd,nlv,ngas+2),tr(idjd,nlv,ngas+3)
  end if
endif  ! (mod(ktau,nmaxpr)==0.and.mydiag)
  
if ( ndi==-ktau ) then
  nmaxpr = 1         ! diagnostic prints; reset 6 lines on
  if ( ndi2==0 ) ndi2 = ktau + 40
endif
if ( ktau==ndi2 ) then
  if ( myid==0 ) write(6,*) 'reset nmaxpr'
  nmaxpr = nmaxprsav
endif
if ( mod(ktau,nmaxpr)==0 .or. ktau==ntau ) then
  call maxmin(u,' u',ktau,1.,kl)
  call maxmin(v,' v',ktau,1.,kl)
  dums(:,:) = u(1:ifull,:)**2 + v(1:ifull,:)**2 ! 3D
  call average(dums,spmean,spavge)
  do k = 1,kl
    spmean(k) = sqrt(spmean(k))
  enddo
  dums(1:ifull,1:kl) = sqrt(dums(1:ifull,1:kl)) ! 3D
  spavge = sqrt(spavge)
  call maxmin(dums,'sp',ktau,1.,kl)
  call maxmin(t,' t',ktau,1.,kl)
  call maxmin(qg,'qg',ktau,1.e3,kl)
  call maxmin(qfg,'qf',ktau,1.e3,kl)
  call maxmin(qlg,'ql',ktau,1.e3,kl)
  call maxmin(sdot,'sd',ktau,1.,kl)  ! grid length units 
  if ( myid==0 ) then
    write(6,'("spmean ",9f8.3)') spmean
    write(6,'("spavge ",f8.3)') spavge
  end if
  dums = qg(1:ifull,:)
  call average(dums,spmean,spavge)
  if ( myid==0 ) then
    write(6,'("qgmean ",9f8.5)') spmean
    write(6,'("qgavge ",f8.5)') spavge
  end if
  call maxmin(wb,'wb',ktau,1.,ms)
  call maxmin(tggsn,'tggsn',ktau,1.,3)
  call maxmin(tgg,'tg',ktau,1.,ms)
  call maxmin(tss,'ts',ktau,1.,1)
  call maxmin(pblh,'pb',ktau,1.,1)
  call maxmin(precip,'pr',ktau,1.,1)
  call maxmin(precc,'pc',ktau,1.,1)
  call maxmin(convpsav,'co',ktau,1.,1)
  call maxmin(sno,'sn',ktau,1.,1)        ! as mm during timestep
  call maxmin(rhscrn,'rh',ktau,1.,1)
  call maxmin(ps,'ps',ktau,.01,1)
  psavge    = sum(ps(1:ifull)*wts(1:ifull))
  pslavge   = sum(psl(1:ifull)*wts(1:ifull))
  preccavge = sum(precc(1:ifull)*wts(1:ifull))
  precavge  = sum(precip(1:ifull)*wts(1:ifull))
  ! KE calculation, not taking into account pressure weighting
  gke = 0.
  do k = 1,kl
    gke = gke - sum( 0.5 * wts(1:ifull) * dsig(k) * ( u(1:ifull,k)**2 + v(1:ifull,k)**2 ) )
  end do
  cllav = sum(wts(1:ifull)*cloudlo(1:ifull))
  clmav = sum(wts(1:ifull)*cloudmi(1:ifull))
  clhav = sum(wts(1:ifull)*cloudhi(1:ifull))
  cltav = sum(wts(1:ifull)*cloudtot(1:ifull))

  ! All this combined into a single reduction
  temparray = (/ psavge, pslavge, preccavge, precavge, gke, cllav, clmav,clhav, cltav /)
  call ccmpi_reduce(temparray(1:9),gtemparray(1:9),"sum",0,comm_world)
  if ( myid==0 ) then
    write(6,97) gtemparray(1:5) ! psavge,pslavge,preccavge,precavge,gke
97  format(' average ps, psl, precc, prec, gke: ',f10.2,f10.6,2f6.2,f7.2)
    write(6,971) gtemparray(6:9) ! cllav,clmav,clhav,cltav
971 format(' global_average cll, clm, clh, clt: ',4f6.2)
  end if
  if ( mydiag ) then
    write(6,98) ktau,diagvals(ps)
98  format(i7,' ps diag:',9f9.1)
    if ( t(idjd,kl)>258. ) then
      write(6,*) 't(idjd,kl) > 258. for idjd = ',idjd
      write(6,91) ktau,(t(idjd,k),k=kl-8,kl)
91    format(i7,'    t',9f7.2)
      write(6,92) ktau,(sdot(idjd,k),k=kl-8,kl)
92    format(i7,' sdot',9f7.3)
    end if             ! (t(idjd,kl)>258.)
  end if               ! myid==0
endif                  ! (mod(ktau,nmaxpr)==0)

return
end subroutine write_diagnostics
    
!-------------------------------------------------------------------- 
! Check for NaN errors
subroutine nantest(message,js,je)

use aerosolldr, only : xtg,ssn,naero  ! LDR prognostic aerosols
use arrays_m                          ! Atmosphere dyamics prognostic arrays
use cc_mpi                            ! CC MPI routines
use cfrac_m                           ! Cloud fraction
use extraout_m                        ! Additional diagnostics
use liqwpar_m                         ! Cloud water mixing ratios
use morepbl_m                         ! Additional boundary layer diagnostics
use newmpar_m                         ! Grid parameters
use parm_m                            ! Model configuration
use pbl_m                             ! Boundary layer arrays
use work2_m                           ! Diagnostic arrays
use work3f_m                          ! Grid work arrays

implicit none

integer, intent(in) :: js, je
character(len=*), intent(in) :: message

if ( js<1 .or. je>ifull ) then
  write(6,*) "ERROR: Invalid index for nantest - ",trim(message)
  call ccmpi_abort(-1)
end if

if ( any(t(js:je,1:kl)/=t(js:je,1:kl)) ) then
  write(6,*) "ERROR: NaN detected in t on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)
end if

if ( any(t(js:je,1:kl)<75.) .or. any(t(js:je,1:kl)>425.) ) then
  write(6,*) "ERROR: Out-of-range detected in t on myid=",myid," at ",trim(message)
  write(6,*) "minval,maxval ",minval(t(js:je,1:kl)),maxval(t(js:je,1:kl))
  write(6,*) "minloc,maxloc ",minloc(t(js:je,1:kl)),maxloc(t(js:je,1:kl))
  call ccmpi_abort(-1)
end if

if ( any(u(js:je,1:kl)/=u(js:je,1:kl)) ) then
  write(6,*) "ERROR: NaN detected in u on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)
end if

if ( any(u(js:je,1:kl)<-400.) .or. any(u(js:je,1:kl)>400.) ) then
  write(6,*) "ERROR: Out-of-range detected in u on myid=",myid," at ",trim(message)
  write(6,*) "minval,maxval ",minval(u(js:je,1:kl)),maxval(u(js:je,1:kl))
  write(6,*) "minloc,maxloc ",minloc(u(js:je,1:kl)),maxloc(u(js:je,1:kl))
  call ccmpi_abort(-1) 
end if

if ( any(v(js:je,1:kl)/=v(js:je,1:kl)) ) then
  write(6,*) "ERROR: NaN detected in v on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)
end if

if ( any(v(js:je,1:kl)<-400.) .or. any(v(js:je,1:kl)>400.) ) then
  write(6,*) "ERROR: Out-of-range detected in v on myid=",myid," at ",trim(message)
  write(6,*) "minval,maxval ",minval(v(js:je,1:kl)),maxval(v(js:je,1:kl))
  write(6,*) "minloc,maxloc ",minloc(v(js:je,1:kl)),maxloc(v(js:je,1:kl))
  call ccmpi_abort(-1) 
end if

if ( any(qg(js:je,1:kl)/=qg(js:je,1:kl)) ) then
  write(6,*) "ERROR: NaN detected in qg on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)
end if

if ( any(qg(js:je,1:kl)<-1.e-8) .or. any(qg(js:je,1:kl)>7.e-2) ) then
  write(6,*) "ERROR: Out-of-range detected in qg on myid=",myid," at ",trim(message)
  write(6,*) "minval,maxval ",minval(qg(js:je,1:kl)),maxval(qg(js:je,1:kl))
  write(6,*) "minloc,maxloc ",minloc(qg(js:je,1:kl)),maxloc(qg(js:je,1:kl))
  call ccmpi_abort(-1) 
end if

if ( any(qlg(js:je,1:kl)/=qlg(js:je,1:kl)) ) then
  write(6,*) "ERROR: NaN detected in qlg on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)    
end if

if ( any(qlg(js:je,1:kl)<-1.e-8) .or. any(qlg(js:je,1:kl)>7.e-2) ) then
  write(6,*) "ERROR: Out-of-range detected in qlg on myid=",myid," at ",trim(message)
  write(6,*) "minval,maxval ",minval(qlg(js:je,1:kl)),maxval(qlg(js:je,1:kl))
  write(6,*) "minloc,maxloc ",minloc(qlg(js:je,1:kl)),maxloc(qlg(js:je,1:kl))
  call ccmpi_abort(-1) 
end if

if ( any(qfg(js:je,1:kl)/=qfg(js:je,1:kl)) ) then
  write(6,*) "ERROR: NaN detected in qfg on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)    
end if

if ( any(qfg(js:je,1:kl)<-1.e-8) .or. any(qfg(js:je,1:kl)>7.e-2) ) then
  write(6,*) "ERROR: Out-of-range detected in qfg on myid=",myid," at ",trim(message)
  write(6,*) "minval,maxval ",minval(qfg(js:je,1:kl)),maxval(qfg(js:je,1:kl))
  write(6,*) "minloc,maxloc ",minloc(qfg(js:je,1:kl)),maxloc(qfg(js:je,1:kl))
  call ccmpi_abort(-1) 
end if

if ( any(qrg(js:je,1:kl)/=qrg(js:je,1:kl)) ) then
  write(6,*) "ERROR: NaN detected in qrg on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)    
end if

if ( any(qrg(js:je,1:kl)<-1.e-8) .or. any(qrg(js:je,1:kl)>7.e-2) ) then
  write(6,*) "ERROR: Out-of-range detected in qrg on myid=",myid," at ",trim(message)
  write(6,*) "minval,maxval ",minval(qrg(js:je,1:kl)),maxval(qrg(js:je,1:kl))
  write(6,*) "minloc,maxloc ",minloc(qrg(js:je,1:kl)),maxloc(qrg(js:je,1:kl))
  call ccmpi_abort(-1) 
end if

if ( any(qsng(js:je,1:kl)/=qsng(js:je,1:kl)) ) then
  write(6,*) "ERROR: NaN detected in qsng on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)    
end if

if ( any(qsng(js:je,1:kl)<-1.e-8) .or. any(qsng(js:je,1:kl)>7.e-2) ) then
  write(6,*) "ERROR: Out-of-range detected in qsng on myid=",myid," at ",trim(message)
  write(6,*) "minval,maxval ",minval(qsng(js:je,1:kl)),maxval(qsng(js:je,1:kl))
  write(6,*) "minloc,maxloc ",minloc(qsng(js:je,1:kl)),maxloc(qsng(js:je,1:kl))
  call ccmpi_abort(-1) 
end if

if ( any(qgrg(js:je,1:kl)/=qgrg(js:je,1:kl)) ) then
  write(6,*) "ERROR: NaN detected in qgrg on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)    
end if

if ( any(qgrg(js:je,1:kl)<-1.e-8) .or. any(qgrg(js:je,1:kl)>7.e-2) ) then
  write(6,*) "ERROR: Out-of-range detected in qgrg on myid=",myid," at ",trim(message)
  write(6,*) "minval,maxval ",minval(qgrg(js:je,1:kl)),maxval(qgrg(js:je,1:kl))
  write(6,*) "minloc,maxloc ",minloc(qgrg(js:je,1:kl)),maxloc(qgrg(js:je,1:kl))
  call ccmpi_abort(-1) 
end if

if ( any(qlrad(js:je,1:kl)/=qlrad(js:je,1:kl)) ) then
  write(6,*) "ERROR: NaN detected in qlrad on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)    
end if

if ( any(qlrad(js:je,1:kl)<-1.e-8) .or. any(qlrad(js:je,1:kl)>7.e-2) ) then
  write(6,*) "ERROR: Out-of-range detected in qlrad on myid=",myid," at ",trim(message)
  write(6,*) "minval,maxval ",minval(qlrad(js:je,1:kl)),maxval(qlrad(js:je,1:kl))
  write(6,*) "minloc,maxloc ",minloc(qlrad(js:je,1:kl)),maxloc(qlrad(js:je,1:kl))
  call ccmpi_abort(-1) 
end if

if ( any(qfrad(js:je,1:kl)/=qfrad(js:je,1:kl)) ) then
  write(6,*) "ERROR: NaN detected in qfrad on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)    
end if

if ( any(qfrad(js:je,1:kl)<-1.e-8) .or. any(qfrad(js:je,1:kl)>7.e-2) ) then
  write(6,*) "ERROR: Out-of-range detected in qfrad on myid=",myid," at ",trim(message)
  write(6,*) "minval,maxval ",minval(qfrad(js:je,1:kl)),maxval(qfrad(js:je,1:kl))
  write(6,*) "minloc,maxloc ",minloc(qfrad(js:je,1:kl)),maxloc(qfrad(js:je,1:kl))
  call ccmpi_abort(-1) 
end if

if ( any(cfrac(js:je,1:kl)/=cfrac(js:je,1:kl)) ) then
  write(6,*) "ERROR: NaN detected in cfrac on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)    
end if

if ( any(cfrac(js:je,1:kl)<-1.e-8) .or. any(cfrac(js:je,1:kl)>1.) ) then
  write(6,*) "ERROR: Out-of-range detected in cfrac on myid=",myid," at ",trim(message)
  write(6,*) "minval,maxval ",minval(cfrac(js:je,1:kl)),maxval(cfrac(js:je,1:kl))
  write(6,*) "minloc,maxloc ",minloc(cfrac(js:je,1:kl)),maxloc(cfrac(js:je,1:kl))
  call ccmpi_abort(-1) 
end if

if ( any(rfrac(js:je,1:kl)/=rfrac(js:je,1:kl)) ) then
  write(6,*) "ERROR: NaN detected in rfrac on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)    
end if

if ( any(rfrac(js:je,1:kl)<-1.e-8) .or. any(rfrac(js:je,1:kl)>1.) ) then
  write(6,*) "ERROR: Out-of-range detected in rfrac on myid=",myid," at ",trim(message)
  write(6,*) "minval,maxval ",minval(rfrac(js:je,1:kl)),maxval(rfrac(js:je,1:kl))
  write(6,*) "minloc,maxloc ",minloc(rfrac(js:je,1:kl)),maxloc(rfrac(js:je,1:kl))
  call ccmpi_abort(-1) 
end if

if ( any(sfrac(js:je,1:kl)/=sfrac(js:je,1:kl)) ) then
  write(6,*) "ERROR: NaN detected in sfrac on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)    
end if

if ( any(sfrac(js:je,1:kl)<-1.e-8) .or. any(sfrac(js:je,1:kl)>1.) ) then
  write(6,*) "ERROR: Out-of-range detected in sfrac on myid=",myid," at ",trim(message)
  write(6,*) "minval,maxval ",minval(sfrac(js:je,1:kl)),maxval(sfrac(js:je,1:kl))
  write(6,*) "minloc,maxloc ",minloc(sfrac(js:je,1:kl)),maxloc(sfrac(js:je,1:kl))
  call ccmpi_abort(-1) 
end if

if ( any(gfrac(js:je,1:kl)/=gfrac(js:je,1:kl)) ) then
  write(6,*) "ERROR: NaN detected in gfrac on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)    
end if

if ( any(gfrac(js:je,1:kl)<-1.e-8) .or. any(gfrac(js:je,1:kl)>1.) ) then
  write(6,*) "ERROR: Out-of-range detected in gfrac on myid=",myid," at ",trim(message)
  write(6,*) "minval,maxval ",minval(gfrac(js:je,1:kl)),maxval(gfrac(js:je,1:kl))
  write(6,*) "minloc,maxloc ",minloc(gfrac(js:je,1:kl)),maxloc(gfrac(js:je,1:kl))
  call ccmpi_abort(-1) 
end if

if ( any(psl(js:je)/=psl(js:je)) ) then
  write(6,*) "ERROR: NaN detected in psl on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)
end if

if ( any(psl(js:je)<-1.4) .or. any(psl(js:je)>0.3) ) then
  write(6,*) "ERROR: Out-of-range detected in psl on myid=",myid," at ",trim(message)
  write(6,*) "minval,maxval ",minval(psl(js:je)),maxval(psl(js:je))
  write(6,*) "minloc,maxloc ",minloc(psl(js:je)),maxloc(psl(js:je))
  call ccmpi_abort(-1) 
end if

if ( any(ps(js:je)/=ps(js:je)) ) then
  write(6,*) "ERROR: NaN detected in ps on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)
end if

if ( any(tss(js:je)/=tss(js:je)) ) then
  write(6,*) "ERROR: NaN detected in tss on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)
end if

if ( any(tss(js:je)<75.) .or. any(tss(js:je)>425.) ) then
  write(6,*) "ERROR: Out-of-range detected in tss on myid=",myid," at ",trim(message)
  write(6,*) "minval,maxval ",minval(tss(js:je)),maxval(tss(js:je))
  write(6,*) "minloc,maxloc ",minloc(tss(js:je)),maxloc(tss(js:je))
  call ccmpi_abort(-1) 
end if

if ( abs(iaero)>=2 ) then
  if ( any(xtg(js:je,1:kl,1:naero)/=xtg(js:je,1:kl,1:naero)) ) then
    write(6,*) "ERROR: NaN detected in xtg on myid=",myid," at ",trim(message)
    call ccmpi_abort(-1)
  end if
  if ( any(xtg(js:je,1:kl,1:naero)<-1.e-8) .or. any(xtg(js:je,1:kl,1:naero)>6.5e-5) ) then
    write(6,*) "ERROR: Out-of-range detected in xtg on myid=",myid," at ",trim(message)
    write(6,*) "minval,maxval ",minval(xtg(js:je,1:kl,1:naero)),maxval(xtg(js:je,1:kl,1:naero))
    write(6,*) "minloc,maxloc ",minloc(xtg(js:je,1:kl,1:naero)),maxloc(xtg(js:je,1:kl,1:naero))
    call ccmpi_abort(-1) 
  end if  
  if ( any(ssn(js:je,1:kl,1:2)/=ssn(js:je,1:kl,1:2)) ) then
    write(6,*) "ERROR: NaN detected in ssn on myid=",myid," at ",trim(message)
    call ccmpi_abort(-1)
  end if
  if ( any(ssn(js:je,1:kl,1:2)<-1.e-8) .or. any(ssn(js:je,1:kl,1:2)>6.5e9) ) then
    write(6,*) "ERROR: Out-of-range detected in ssn on myid=",myid," at ",trim(message)
    write(6,*) "minval,maxval ",minval(ssn(js:je,1:kl,1:2)),maxval(ssn(js:je,1:kl,1:2))
    write(6,*) "minloc,maxloc ",minloc(ssn(js:je,1:kl,1:2)),maxloc(ssn(js:je,1:kl,1:2))
    call ccmpi_abort(-1) 
  end if    
end if

if ( any( fg(js:je)/=fg(js:je) ) ) then
  write(6,*) "ERROR: NaN detected in fg on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)
end if

if ( any( eg(js:je)/=eg(js:je) ) ) then
  write(6,*) "ERROR: NaN detected in eg on myid=",myid," at ",trim(message)
  call ccmpi_abort(-1)
end if

return
end subroutine nantest
