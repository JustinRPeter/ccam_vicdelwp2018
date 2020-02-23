! Conformal Cubic Atmospheric Model
    
! Copyright 2015-2020 Commonwealth Scientific Industrial Research Organisation (CSIRO)
    
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
    
! This module is the Rotstayn 1997 cloud microphysics parameterisation

! The scheme has been modifed by MJT for max/rnd cloud overlap and to include prognostic rainfall, snow and
! graupel.  The snow and graupel components are based on Lin et al 1983, with modifications to the slope
! and intercept to be consistent with Rotstayn 97. There is also an optional prognostic cloud fraction option
! based on Tiedtke (see cloudmod.f90).

! ldr    = 0    Diagnosed cloud scheme (depreciated)
! ldr   /= 0    Prognostic cloud condensate (different ice fall speed options)
    
! ncloud = 0    Standard LDR cloud microphysics with water vapour, liquid cloud and ice cloud
! ncloud = 2    Same as ncloud=0, but with prognostic rain and modified cfrac
! ncloud = 3    Same as ncloud=2, but with prognostic graupel and snow, as well as modified cfrac
! ncloud = 4    Use prognostic cloud fraction based on Tiedtke from GFDL-CM3, but autoconversion from ncloud=0
   
!                            Water vapour (qg)
!
!   Cloud water (qlg,cfrac)                      Cloud ice (qfg,cfrac)
!
!   Rain (qrg,rfrac)                             Snow (qsg,sfrac)         Graupel (qgrg,gfrac)

! qg, qlg, qfg, qrg, qsg and qgrg are mixing ratios (g/g) and cfrac, rfrac, sfrac, gfrac are area cover
! fractions
    
module leoncld_mod

private
public leoncld
public rhow, rhoice, um, Dva, rKa
public ti, tice, aa, bb
public Ec, Aurate
public rhosno, Eac
public Nor, rk2, rho0, Ecol
public wlc, wls, ticon
public aice, bice

real, parameter :: maxlintime = 120. ! time-step for Lin et al 83 cloud microphysics

! Physical constants
real, parameter :: rhow=1000.  !Density of water
real, parameter :: rhoice=917. !Density of ice
real, parameter :: um=1.717e-5 !Dynamic viscosity of air (at 0 deg. C)
real, parameter :: Dva=2.21    !Diffusivity of qv in air (0 deg. and 1 Pa)
real, parameter :: rKa=2.4e-2  !Thermal conductivity of air (0 deg)

! Tunable parameters for qcloud scheme
real, parameter :: ti = -40.               ! Min T for liquid water clouds in Celsius
real, parameter :: tice=273.15+ti          !Convert ti to Kelvin
real, parameter :: aa=-2/ti**3, bb=3/ti**2 ! Coeffs for cubic interp of fracice

! The following are used in the Manton-Cotton rain parameterization
real, parameter :: Ec=0.55                 !Mean collection efficiency for cloud drops
real, parameter :: Aurate=0.104*9.80616*Ec/um !Part of rate constant

! Parameters related to snow
real, parameter :: rhosno=100. !Assumed density of snow in kg/m^3
real, parameter :: Eac=0.7     !Mean collection efficiency of ql by snow

! Parameters related to rain
real, parameter :: Nor=8.0e6 !Marshall-Palmer intercept parameter
real, parameter :: rk2=142.  !Fall speed of rain: V(D)=rk2*sqrt(D)*sqrt(rho0/rhoa)
real, parameter :: rho0=1.2  !Standard air density
real, parameter :: Ecol=0.7  !Mean collection efficiency of ql by rain

! Parameters related to diagnosed convective cloud
real, parameter :: wlc=0.2e-3   !LWC of deep conv cloud (kg/m**3)
real, parameter :: wls=0.35e-3  !LWC of shallow (non-preciptating) conv cloud
real, parameter :: ticon=238.15 !Temp at which conv cloud becomes ice

! Parameters related to cloud radiative properties
real, parameter :: aice=1.016 !Constant in Platt optical depth for ice (SI units)
real, parameter :: bice=0.68  !Constant in Platt optical depth for ice (SI units)

interface pow75
  module procedure pow75_s, pow75_v
end interface

contains
    
subroutine leoncld

use aerointerface                 ! Aerosol interface
use arrays_m                      ! Atmosphere dyamics prognostic arrays
use cc_mpi, only : mydiag         ! CC MPI routines
use cc_omp                        ! CC OpenMP routines
use cfrac_m                       ! Cloud fraction
use cloudmod                      ! Prognostic cloud fraction
use const_phys                    ! Physical constants
use kuocomb_m                     ! JLM convection
use liqwpar_m                     ! Cloud water mixing ratios
use map_m                         ! Grid map arrays
use morepbl_m                     ! Additional boundary layer diagnostics
use newmpar_m                     ! Grid parameters
use nharrs_m                      ! Non-hydrostatic atmosphere arrays 
use parm_m, only : idjd, iaero
                                  ! Model configuration
use prec_m                        ! Precipitation
use sigs_m                        ! Atmosphere sigma levels
use soil_m                        ! Soil and surface data
use work3f_m                      ! Grid work arrays
use vvel_m                        ! Additional vertical velocity

implicit none

include 'kuocom.h'                ! Convection parameters

integer tile, is, ie, k
integer idjd_t
real, dimension(imax,kl) :: lcfrac, lgfrac, lppfevap, lppfmelt, lppfprec, lppfsnow
real, dimension(imax,kl) :: lppfstayice, lppfstayliq, lppfsubl, lpplambs, lppmaccr, lppmrate
real, dimension(imax,kl) :: lppqfsedice, lpprfreeze, lpprscav, lqccon, lqfg, lqfrad
real, dimension(imax,kl) :: lqg, lqgrg, lqlg, lqlrad, lqrg, lqsng, lrfrac, lsfrac, lt
real, dimension(imax,kl) :: ldpsldt, lnettend, lstratcloud, lclcon, lcdrop, lrhoa
real, dimension(ifull,kl) :: clcon, cdrop
logical mydiag_t

!$omp do schedule(static) private(is,ie),                                             &
!$omp private(lrhoa,lcdrop,lclcon)
do tile = 1,ntiles
  is = (tile-1)*imax + 1
  ie = tile*imax

  ! Calculate droplet concentration from aerosols (for non-convective faction of grid-box)
  do k = 1,kl
    lrhoa(:,k) = ps(is:ie)*sig(k)/(rdry*t(is:ie,k))  
  end do
  call aerodrop(is,lcdrop,lrhoa,outconv=.true.)
  cdrop(is:ie,:) = lcdrop

  ! Calculate convective cloud fraction
  call convectivecloudfrac(lclcon,kbsav(is:ie),ktsav(is:ie),condc(is:ie))
  clcon(is:ie,:) = lclcon
end do
!$omp end do nowait

!$omp do schedule(static) private(is,ie),                                             &
!$omp private(lcfrac,lgfrac),                                                         &
!$omp private(lppfevap,lppfmelt,lppfprec,lppfsnow,lppfstayice,lppfstayliq,lppfsubl),  &
!$omp private(lpplambs,lppmaccr,lppmrate,lppqfsedice,lpprfreeze,lpprscav),            &
!$omp private(lqccon,lqfg,lqfrad,lqg,lqgrg,lqlg,lqlrad,lqrg,lqsng,lrfrac,lsfrac,lt),  &
!$omp private(ldpsldt,lnettend,lstratcloud,lclcon,lcdrop,idjd_t,mydiag_t)
!$acc parallel copy(stratcloud,gfrac,rfrac,sfrac,t,qg,qgrg,qlg,qfg,qrg,qsng,nettend,   &
!$acc   condg,conds,condx,precip)                                                      &
!$acc copyin(dpsldt,clcon,cdrop,kbsav,ktsav,land,ps,em)                                &
!$acc copyout(cfrac,qlrad,qfrad,qccon,ppfevap,ppfmelt,ppfprec,ppfsnow,ppfstayice,      &
!$acc   ppfstayliq,ppfsubl,pplambs,ppmaccr,ppmrate,ppqfsedice,pprfreeze,pprscav)
!$acc loop gang private(lcfrac,lgfrac,lppfevap,lppfmelt,lppfprec,lppfsnow,lppfstayice, &
!$acc   lppfstayliq,lppfsubl,lpplambs,lppmaccr,lppmrate,lppqfsedice,lpprfreeze,        &
!$acc   lpprscav,lqccon,lqfg,lqfrad,lqg,lqgrg,lqlg,lqlrad,lqrg,lqsng,lrfrac,lsfrac,lt, &
!$acc   ldpsldt,lnettend,lstratcloud,lclcon,lcdrop)
do tile = 1,ntiles
  is = (tile-1)*imax + 1
  ie = tile*imax
  
  idjd_t = mod(idjd-1,imax)+1
  mydiag_t = ((idjd-1)/imax==tile-1).and.mydiag
  
  lcfrac   = cfrac(is:ie,:)
  lgfrac   = gfrac(is:ie,:)
  lrfrac   = rfrac(is:ie,:)
  lsfrac   = sfrac(is:ie,:)
  lqg      = qg(is:ie,:)
  lqgrg    = qgrg(is:ie,:)
  lqlg     = qlg(is:ie,:)
  lqfg     = qfg(is:ie,:)
  lqrg     = qrg(is:ie,:)
  lqsng    = qsng(is:ie,:)
  lqlrad   = qlrad(is:ie,:)
  lqfrad   = qfrad(is:ie,:)  
  lt       = t(is:ie,:)
  ldpsldt  = dpsldt(is:ie,:)
  lclcon   = clcon(is:ie,:)
  lcdrop   = cdrop(is:ie,:)
  if ( ncloud>=4 ) then
    lnettend    = nettend(is:ie,:)
    lstratcloud = stratcloud(is:ie,:)
  else
    lstratcloud = cfrac(is:ie,:)
  end if

  call leoncld_work(lcfrac,condg(is:ie),conds(is:ie),condx(is:ie),lgfrac,                           &
                    kbsav(is:ie),ktsav(is:ie),land(is:ie),                                          &
                    lppfevap,lppfmelt,lppfprec,lppfsnow,lppfstayice,lppfstayliq,lppfsubl,           &
                    lpplambs,lppmaccr,lppmrate,lppqfsedice,lpprfreeze,lpprscav,precip(is:ie),       &
                    ps(is:ie),lqccon,lqfg,lqfrad,lqg,lqgrg,lqlg,lqlrad,lqrg,lqsng,lrfrac,lsfrac,lt, &
                    ldpsldt,lnettend,lstratcloud,lclcon,lcdrop,em(is:ie),idjd_t,mydiag_t,is,        &
                    ncloud,nclddia,nevapls,ldr,rcrit_l,rcrit_s,rcm,imax,kl)

  cfrac(is:ie,:) = lcfrac
  gfrac(is:ie,:) = lgfrac
  rfrac(is:ie,:) = lrfrac
  sfrac(is:ie,:) = lsfrac
  qccon(is:ie,:) = lqccon
  qg(is:ie,:)    = lqg
  qlg(is:ie,:)   = lqlg
  qfg(is:ie,:)   = lqfg
  qrg(is:ie,:)   = lqrg
  qsng(is:ie,:)  = lqsng
  qgrg(is:ie,:)  = lqgrg
  qlrad(is:ie,:) = lqlrad
  qfrad(is:ie,:) = lqfrad
  t(is:ie,:)     = lt
  if ( abs(iaero)>=2 ) then
    ppfevap(is:ie,:)    = lppfevap
    ppfmelt(is:ie,:)    = lppfmelt
    ppfprec(is:ie,:)    = lppfprec
    ppfsnow(is:ie,:)    = lppfsnow
    ppfstayice(is:ie,:) = lppfstayice
    ppfstayliq(is:ie,:) = lppfstayliq
    ppfsubl(is:ie,:)    = lppfsubl
    pplambs(is:ie,:)    = lpplambs
    ppmaccr(is:ie,:)    = lppmaccr
    ppmrate(is:ie,:)    = lppmrate
    ppqfsedice(is:ie,:) = lppqfsedice
    pprfreeze(is:ie,:)  = lpprfreeze
    pprscav(is:ie,:)    = lpprscav
  end if
  if ( ncloud>=4 ) then
    nettend(is:ie,:)    = lnettend
    stratcloud(is:ie,:) = lstratcloud
  end if
  
end do
!$acc end parallel
!$omp end do nowait

return
end subroutine leoncld

! This subroutine is the interface for the LDR cloud microphysics
subroutine leoncld_work(cfrac,condg,conds,condx,gfrac,kbsav,ktsav,land,                 &
                        ppfevap,ppfmelt,ppfprec,ppfsnow,ppfstayice,ppfstayliq,ppfsubl,  &
                        pplambs,ppmaccr,ppmrate,ppqfsedice,pprfreeze,pprscav,precip,    &
                        ps,qccon,qfg,qfrad,qg,qgrg,qlg,qlrad,qrg,qsng,rfrac,sfrac,t,    &
                        dpsldt,nettend,stratcloud,clcon,cdrop,em,idjd,mydiag,is,        &
                        ncloud,nclddia,nevapls,ldr,rcrit_l,rcrit_s,rcm,imax,kl)
!$acc routine vector

use const_phys                    ! Physical constants
use estab                         ! Liquid saturation function
use parm_m, only : iaero, nmaxpr, dt
                                  ! Model configuration
use sigs_m                        ! Atmosphere sigma levels

implicit none

integer, intent(in) :: idjd, is, ncloud, nclddia, nevapls, ldr
integer, intent(in) :: imax, kl
integer, dimension(imax), intent(in) :: kbsav
integer, dimension(imax), intent(in) :: ktsav
real, dimension(imax,kl), intent(inout) :: cfrac, gfrac, rfrac, sfrac
real, dimension(imax,kl), intent(inout) :: qg, qlg, qfg, qrg, qsng, qgrg
real, dimension(imax,kl), intent(inout) :: qlrad, qfrad
real, dimension(imax,kl), intent(inout) :: t
real, dimension(imax,kl), intent(inout) :: nettend
real, dimension(imax,kl), intent(inout) :: stratcloud, clcon, cdrop
real, dimension(imax,kl), intent(out) :: qccon
real, dimension(imax,kl), intent(out) :: ppfevap
real, dimension(imax,kl), intent(out) :: ppfmelt
real, dimension(imax,kl), intent(out) :: ppfprec
real, dimension(imax,kl), intent(out) :: ppfsnow
real, dimension(imax,kl), intent(out) :: ppfstayice
real, dimension(imax,kl), intent(out) :: ppfstayliq
real, dimension(imax,kl), intent(out) :: ppfsubl
real, dimension(imax,kl), intent(out) :: pplambs
real, dimension(imax,kl), intent(out) :: ppmaccr
real, dimension(imax,kl), intent(out) :: ppmrate
real, dimension(imax,kl), intent(out) :: ppqfsedice
real, dimension(imax,kl), intent(out) :: pprfreeze
real, dimension(imax,kl), intent(out) :: pprscav
real, dimension(imax,kl), intent(in) :: dpsldt
real, dimension(imax), intent(inout) :: condg
real, dimension(imax), intent(inout) :: conds
real, dimension(imax), intent(inout) :: condx
real, dimension(imax), intent(inout) :: precip
real, dimension(imax), intent(in) :: ps
real, dimension(imax), intent(in) :: em
real, intent(in) :: rcrit_l, rcrit_s, rcm
logical, intent(in) :: mydiag
logical, dimension(imax), intent(in) :: land

integer, dimension(imax) :: kbase,ktop          !Bottom and top of convective cloud 
real, dimension(imax,kl) :: prf      !Pressure on full levels (hPa)
real, dimension(imax,kl) :: dprf     !Pressure thickness (hPa)
real, dimension(imax,kl) :: rhoa     !Air density (kg/m3)
real, dimension(imax,kl) :: dz       !Layer thickness (m)
real, dimension(imax,kl) :: ccov     !Cloud cover (may differ from cloud frac if vertically subgrid)
real, dimension(imax,kl) :: qsatg    !Saturation mixing ratio
real, dimension(imax,kl) :: qcl      !Vapour mixing ratio inside convective cloud
real, dimension(imax,kl) :: qenv     !Vapour mixing ratio outside convective cloud
real, dimension(imax,kl) :: tenv     !Temperature outside convective cloud
real, dimension(imax) :: precs                  !Amount of stratiform precipitation in timestep (mm)
real, dimension(imax) :: preci                  !Amount of stratiform snowfall in timestep (mm)
real, dimension(imax) :: precg                  !Amount of stratiform graupel in timestep (mm)
real, dimension(imax) :: wcon                   !Convective cloud water content (in-cloud, prescribed)

integer k
real, dimension(imax,kl) :: qevap, qsubl, qauto, qcoll, qaccr, qaccf
real, dimension(imax,kl) :: fluxr, fluxi, fluxs, fluxg, fluxm, fluxf
real, dimension(imax,kl) :: pqfsedice, pfstayice, pfstayliq, pslopes, prscav
real, dimension(imax) :: prf_temp, fl
real, dimension(imax) :: rhodz
real, dimension(imax) :: diag_temp
real invdt

! meterological fields
do k = 1,kl
  prf_temp(:) = ps*sig(k)
  prf(:,k)    = 0.01*prf_temp    !ps is SI units
  dprf(:,k)   = -0.01*ps*dsig(k) !dsig is -ve
  rhoa(:,k)   = prf_temp/(rdry*t(:,k))             ! air density
  qsatg(:,k)  = qsat(prf_temp,t(:,k))              ! saturated mixing ratio
  dz(:,k)     = -rdry*dsig(k)*t(:,k)/(grav*sig(k)) ! level thickness in metres 
  dz(:,k)     = min( max(dz(:,k), 1.), 2.e4 )
end do
 
! default values
kbase(:) = 0  ! default
ktop(:)  = 0  ! default
precs(:) = 0. ! rain
preci(:) = 0. ! snow
precg(:) = 0. ! graupel

!     Set up convective cloud column
where ( ktsav(:)<kl-1 )
  ktop(:)  = ktsav(:)
  kbase(:) = kbsav(:) + 1
  wcon(:)  = wlc
elsewhere
  wcon(:)  = 0.
end where


#ifndef GPU
if ( nmaxpr==1 .and. mydiag ) then
  !if ( ktau==1 ) then
  !  write(6,*)'in leoncloud Rcm ',Rcm
  !end if
  write(6,*) 'entering leoncld'
  diag_temp(:) = qg(idjd,:)
  write(6,"('qv  ',9f8.3/4x,9f8.3)") diag_temp(:)
  diag_temp(:) = qfg(idjd,:)
  write(6,"('qf  ',9f8.3/4x,9f8.3)") diag_temp(:)
  diag_temp(:) = qlg(idjd,:)
  write(6,"('ql  ',9f8.3/4x,9f8.3)") diag_temp(:)
  diag_temp(:) = qrg(idjd,:)
  write(6,"('qr  ',9f8.3/4x,9f8.3)") diag_temp(:)
  diag_temp(:) = qsng(idjd,:)
  write(6,"('qs  ',9f8.3/4x,9f8.3)") diag_temp(:)
  diag_temp(:) = qgrg(idjd,:) 
  write(6,"('qg  ',9f8.3/4x,9f8.3)") diag_temp(:)
endif
#endif


! Calculate convective cloud fraction and adjust moisture variables before calling newcloud
do k = 1,kl
  where ( clcon(:,k)>0. )  
    !ccw=wcon(iq)/rhoa(iq,k)  !In-cloud l.w. mixing ratio
    qccon(:,k)  = clcon(:,k)*wcon(:)/rhoa(:,k)  
    qenv(:,k)   = max( 1.e-8, (qg(:,k)-clcon(:,k)*max(qsatg(:,k),qg(:,k)))/(1.-clcon(:,k)) )
    qcl(:,k)    = (qg(:,k)-(1.-clcon(:,k))*qenv(:,k))/clcon(:,k)
    qlg(:,k)    = qlg(:,k)/(1.-clcon(:,k))  
    qfg(:,k)    = qfg(:,k)/(1.-clcon(:,k))  
    stratcloud(:,k) = stratcloud(:,k)/(1.-clcon(:,k)) 
  elsewhere
    qccon(:,k)  = 0.  
    qcl(:,k)    = qg(:,k)
    qenv(:,k)   = qg(:,k)
  end where    
  tenv(:,k)   = t(:,k) ! Assume T is the same in and out of convective cloud
end do


#ifndef GPU
if ( nmaxpr==1 .and. mydiag ) then
  write(6,*) 'before newcloud'
  diag_temp(:) = t(idjd,:)
  write(6,"('t   ',9f8.2/4x,9f8.2)") diag_temp
  diag_temp(:) = qg(idjd,:)
  write(6,"('qv  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qfg(idjd,:)
  write(6,"('qf  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qlg(idjd,:)
  write(6,"('ql  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qrg(idjd,:)
  write(6,"('qr  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qsng(idjd,:)
  write(6,"('qs  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qgrg(idjd,:)
  write(6,"('qg  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qenv(idjd,:)
  write(6,"('qnv ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qsatg(idjd,:)
  write(6,"('qsat',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qcl(idjd,:)
  write(6,"('qcl ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = clcon(idjd,:)
  write(6,"('clc ',9f8.3/4x,9f8.3)") diag_temp
  write(6,*) 'kbase,ktop ',kbase(idjd),ktop(idjd)
endif
#endif


!     Calculate cloud fraction and cloud water mixing ratios
call newcloud(dt,land,prf,rhoa,cdrop,tenv,qenv,qlg,qfg, &
              dpsldt,nettend,stratcloud,em,idjd,mydiag, &
              ncloud,nclddia,rcrit_l,rcrit_s,imax,kl)


! Vertically sub-grid cloud
do k = 1,kl
  ccov(:,k) = stratcloud(:,k)
end do
do k = 2,kl-1
  where ( stratcloud(:,k-1)<1.e-10 .and. stratcloud(:,k)>1.e-2 .and. stratcloud(:,k+1)<1.e-10 )
    ccov(:,k) = sqrt(stratcloud(:,k))
  end where
end do
     

#ifndef GPU
if ( nmaxpr==1 .and. mydiag ) then
  write(6,*) 'after newcloud'
  diag_temp(:) = tenv(idjd,:)
  write (6,"('tnv ',9f8.2/4x,9f8.2)") diag_temp
  diag_temp(:) = qg(idjd,:) 
  write (6,"('qv0 ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qfg(idjd,:)
  write (6,"('qf  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qlg(idjd,:)
  write (6,"('ql  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qrg(idjd,:)
  write (6,"('qr  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qsng(idjd,:)
  write (6,"('qs  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qgrg(idjd,:)
  write (6,"('qg  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qenv(idjd,:) ! really new qg
  write (6,"('qnv ',9f8.3/4x,9f8.3)") diag_temp
endif
#endif


!     Weight output variables according to non-convective fraction of grid-box            
do k = 1,kl
  t(:,k)  = clcon(:,k)*t(:,k) + (1.-clcon(:,k))*tenv(:,k)
  qg(:,k) = clcon(:,k)*qcl(:,k) + (1.-clcon(:,k))*qenv(:,k)
  where ( k>=kbase(:) .and. k<=ktop(:) )
    stratcloud(:,k) = stratcloud(:,k)*(1.-clcon(:,k))
    ccov(:,k)  = ccov(:,k)*(1.-clcon(:,k))              
    qlg(:,k)   = qlg(:,k)*(1.-clcon(:,k))
    qfg(:,k)   = qfg(:,k)*(1.-clcon(:,k))
  end where  
end do


#ifndef GPU
if ( nmaxpr==1 .and. mydiag ) then
  write(6,*) 'before newsnowrain'
  diag_temp(:) = t(idjd,:)
  write (6,"('t   ',9f8.2/4x,9f8.2)") diag_temp
  diag_temp(:) = qg(idjd,:)
  write (6,"('qv  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qfg(idjd,:)
  write (6,"('qf  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qlg(idjd,:)
  write (6,"('ql  ',9f8.3/4x,9f8.3)") diag_temp
endif
!if ( diag .and. ntiles==1 ) then
!  call maxmin(t,' t',ktau,1.,kl)
!  call maxmin(qg,'qv',ktau,1.e3,kl)
!  call maxmin(qfg,'qf',ktau,1.e3,kl)
!  call maxmin(qlg,'ql',ktau,1.e3,kl)
!  call maxmin(qrg,'qr',ktau,1.e3,kl)
!  call maxmin(qsng,'qs',ktau,1.e3,kl)
!  call maxmin(qgrg,'qg',ktau,1.e3,kl)
!endif
#endif


! Add convective cloud water into fields for radiation
! done because sometimes newrain drops out all qlg, ending up with 
! zero cloud (although it will be rediagnosed as 1 next timestep)
do k = 1,kl
  fl(:)      = max(0., min(1., (t(:,k)-ticon)/(273.15-ticon)))
  qlrad(:,k) = qlg(:,k) + fl(:)*qccon(:,k)
  qfrad(:,k) = qfg(:,k) + (1.-fl(:))*qccon(:,k)
  cfrac(:,:) = min( 1., ccov(:,:)+clcon(:,:) ) ! original
end do


!     Calculate precipitation and related processes
call newsnowrain(dt,rhoa,dz,prf,cdrop,t,qlg,qfg,qrg,qsng,qgrg,                    &
                 precs,qg,stratcloud,rfrac,sfrac,gfrac,preci,precg,qevap,qsubl,   &
                 qauto,qcoll,qaccr,qaccf,fluxr,fluxi,fluxs,fluxg,fluxm,           &
                 fluxf,pfstayice,pfstayliq,pqfsedice,pslopes,prscav,              &
                 condx,ktsav,idjd,mydiag,ncloud,nevapls,ldr,rcm,imax,kl)


#ifndef GPU
if ( nmaxpr==1 .and. mydiag ) then
  write(6,*) 'after newsnowrain'
  diag_temp(:) = t(idjd,:)
  write (6,"('t   ',9f8.2/4x,9f8.2)") diag_temp
  diag_temp(:) = qg(idjd,:)
  write (6,"('qv  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qfg(idjd,:)
  write (6,"('qf  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qlg(idjd,:)
  write (6,"('ql  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qrg(idjd,:)
  write (6,"('qr  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qsng(idjd,:)
  write (6,"('qs  ',9f8.3/4x,9f8.3)") diag_temp
  diag_temp(:) = qgrg(idjd,:)
  write (6,"('qg  ',9f8.3/4x,9f8.3)") diag_temp
end if
!if ( diag .and. ntiles==1 ) then
!  call maxmin(t,' t',ktau,1.,kl)
!  call maxmin(qg,'qv',ktau,1.e3,kl)
!  call maxmin(qfg,'qf',ktau,1.e3,kl)
!  call maxmin(qlg,'ql',ktau,1.e3,kl)
!  call maxmin(qrg,'qr',ktau,1.e3,kl)
!  call maxmin(qsng,'qs',ktau,1.e3,kl)
!  call maxmin(qgrg,'qg',ktau,1.e3,kl)
!endif
#endif


!--------------------------------------------------------------
! Store data needed by prognostic aerosol scheme
! MJT notes - invert levels for aerosol code
if ( abs(iaero)>=2 ) then
  invdt = 1./dt
  ppfprec(:,1) = 0.   !At TOA
  ppfmelt(:,1) = 0.   !At TOA
  ppfsnow(:,1) = 0.   !At TOA
  pprfreeze(:,1) = 0. !At TOA
  do k = 1,kl-1
    ppfprec(:,kl+1-k) = (fluxr(:,k+1)+fluxm(:,k)-fluxf(:,k))*invdt     !flux *entering* layer k
    ppfmelt(:,kl+1-k) = fluxm(:,k)*invdt                               !flux melting in layer k
    ppfsnow(:,kl+1-k) = (fluxi(:,k+1)+fluxs(:,k+1)+fluxg(:,k+1) &
                        -fluxm(:,k)+fluxf(:,k))*invdt                  !flux *entering* layer k
    pprfreeze(:,kl+1-k) = fluxf(:,k)*invdt                             !flux freezing in layer k
  end do
  do k = 1,kl
    rhodz(:)             = rhoa(:,k)*dz(:,k)
    ppfevap(:,kl+1-k)    = qevap(:,k)*rhodz*invdt
    ppfsubl(:,kl+1-k)    = qsubl(:,k)*rhodz*invdt !flux sublimating or staying in k
    pplambs(:,kl+1-k)    = pslopes(:,k)
    ppmrate(:,kl+1-k)    = (qauto(:,k)+qcoll(:,k))*invdt
    ppmaccr(:,kl+1-k)    = qaccr(:,k)*invdt
    ppfstayice(:,kl+1-k) = pfstayice(:,k)
    ppfstayliq(:,kl+1-k) = pfstayliq(:,k)
    ppqfsedice(:,kl+1-k) = pqfsedice(:,k)
    pprscav(:,kl+1-k)    = prscav(:,k)
  end do
end if
!--------------------------------------------------------------


!========================= Jack's diag stuff =========================
!if ( ncfrp==1 ) then  ! from here to near end; Jack's diag stuff
!  do iq = 1,icfrp
!    tautot(iq)  = 0.
!    cldmax(iq)  = 0.
!    ctoptmp(iq) = 0.
!    ctoppre(iq) = 0.
!    do k = 1,kl
!      fice(iq,k) = 0.
!    enddo
!    kcldfmax(iq) = 0.
!  enddo
!!      cfrp data
!  do k = 1,kl-1
!    do iq = 1,icfrp
!      taul(iq,k) = 0.
!      taui(iq,k) = 0.
!      Reffl = 0.
!      if ( stratcloud(iq,k)>0. ) then
!        tau_sfac = 1.
!        fice(iq,k) = qfrad(iq,k)/(qfrad(iq,k)+qlrad(iq,k)) ! 16/1/06
!!            Liquid water clouds
!        if ( qlg(iq,k)>1.0e-8 ) then
!          Wliq = rhoa(iq,k)*qlg(iq,k)/(stratcloud(iq,k)*(1-fice(iq,k))) !kg/m^3
!          if ( .not.land(iq) ) then !sea
!            rk = 0.8
!          else            !land
!            rk = 0.67
!          endif
!! Reffl is the effective radius at the top of the cloud (calculated following
!! Martin etal 1994, JAS 51, 1823-1842) due to the extra factor of 2 in the
!! formula for reffl. Use mid cloud value of Reff for emissivity.
!          Reffl = (3*2*Wliq/(4*rhow*pi*rk*cdrop(iq,k)))**(1./3)
!          qlpath = Wliq*dz(iq,k)
!          taul(iq,k) = tau_sfac*1.5*qlpath/(rhow*Reffl)
!        endif ! qlg
!! Ice clouds
!        if ( qfg(iq,k)>1.0e-8 ) then
!          Wice = rhoa(iq,k)*qfg(iq,k)/(stratcloud(iq,k)*fice(iq,k)) !kg/m**3
!          sigmai = aice*Wice**bice !visible ext. coeff. for ice
!          taui(iq,k) = sigmai*dz(iq,k) !visible opt. depth for ice
!          taui(iq,k) = tau_sfac*taui(iq,k)
!        endif ! qfg
!      endif !stratcloud
!    enddo ! iq
!  enddo ! k
!! Code to get vertically integrated value...
!! top down to get highest level with stratcloud=cldmax (kcldfmax)
!  do k = kl-1,1,-1
!    do iq = 1,icfrp
!      tautot(iq) = tautot(iq)+stratcloud(iq,k)*(fice(iq,k)*taui(iq,k)+(1.-fice(iq,k))*taul(iq,k))
!      if ( stratcloud(iq,k)>cldmax(iq) ) kcldfmax(iq) = k
!      cldmax(iq) = max(cldmax(iq),stratcloud(iq,k))
!    enddo ! iq
!  enddo ! k
!
!  do iq = 1,icfrp
!    if ( cldmax(iq)>1.e-10 ) then
!      tautot(iq) = tautot(iq)/cldmax(iq)
!
!      cfd = 0.
!      do k = kl,kcldfmax(iq),-1
!        fcf = max(0.,stratcloud(iq,k)-cfd) ! cld frac. from above
!        ctoptmp(iq) = ctoptmp(iq)+fcf*t(iq,k)/cldmax(iq)
!        ctoppre(iq) = ctoppre(iq)+fcf*prf(iq,k)/cldmax(iq)
!        cfd = max(stratcloud(iq,k),cfd)
!      enddo ! k=kl,kcldfmax(iq),-1
!
!    endif ! (cldmax(iq).gt.1.e-10) then
!  enddo   ! iq
!endif    ! ncfrp.eq.1
!========================= end of Jack's diag stuff ======================

condx(:)  = condx(:) + precs(:)
conds(:)  = conds(:) + preci(:)
condg(:)  = condg(:) + precg(:)
precip(:) = precip(:) + precs(:)

return
end subroutine leoncld_work


! from arguments
!      ttg - temperature (K)
!      qtg - water vapour mixing ratio (kg/kg) - called qenv in leoncld
!      qlg - cloud liquid water mixing ratio (kg/kg)
!      qfg - cloud ice mixing ratio (kg/kg)
!
! Output:
!
! from arguments
!      stratcloud - cloudy fraction of grid box
! 
!******************************************************************************

 subroutine newcloud(tdt,land,prf,rhoa,cdrop,ttg,qtg,qlg,qfg,  &
                     dpsldt,nettend,stratcloud,em,idjd,mydiag, &
                     ncloud,nclddia,rcrit_l,rcrit_s,imax,kl)
!$acc routine vector
 
! This routine is part of the prognostic cloud water scheme

use const_phys                    ! Physical constants
use estab                         ! Liquid saturation function
use parm_m, only : diag, ds       ! Model configuration
use sigs_m                        ! Atmosphere sigma levels
 
implicit none

! Argument list
integer, intent(in) :: idjd, ncloud, nclddia
integer, intent(in) :: imax, kl
real, dimension(imax,kl), intent(in) :: prf
real, dimension(imax,kl), intent(in) :: rhoa
real, dimension(imax,kl), intent(in) :: cdrop
real, dimension(imax,kl), intent(inout) :: ttg
real, dimension(imax,kl), intent(inout) :: qtg
real, dimension(imax,kl), intent(inout) :: qlg
real, dimension(imax,kl), intent(inout) :: qfg
real, dimension(imax,kl), intent(in) :: dpsldt
real, dimension(imax,kl), intent(inout) :: nettend
real, dimension(imax,kl), intent(inout) :: stratcloud
real, dimension(imax), intent(in) :: em
real, intent(in) :: tdt
real, intent(in) :: rcrit_l, rcrit_s
logical, intent(in) :: mydiag
logical, dimension(imax), intent(in) :: land

! Local work arrays and variables
real, dimension(imax,kl) :: qsl, qsw
real, dimension(imax,kl) :: qcg, qtot, tliq
real, dimension(imax,kl) :: fice, qcold, rcrit
real, dimension(imax,kl) :: qsi, qfnew
real, dimension(imax) :: tk, fl
real :: es, Aprpr, Bprpr, Cice
real :: qi0, fd, Crate, Qfdep
real, dimension(imax) :: hlrvap, pk, deles, dqsdt
real, dimension(imax) :: al, qs, delq
real, dimension(imax) :: qc
real, dimension(imax) :: diag_temp

integer k, iq

real decayfac
real, parameter :: rhoic = 700.
real, parameter :: cm0 = 1.e-12 !Initial crystal mass

! Start code : ----------------------------------------------------------


#ifndef GPU
if ( diag.and.mydiag ) then
  write(6,*) 'entering newcloud'
  diag_temp(:) = prf(idjd,:)
  write(6,'(a,30f10.3)') 'prf ',diag_temp
  diag_temp(:) = ttg(idjd,:)
  write(6,'(a,30f10.3)') 'ttg ',diag_temp
  diag_temp(:) = qtg(idjd,:)
  write(6,*) 'qtg ',diag_temp
  diag_temp(:) = qlg(idjd,:)
  write(6,*) 'qlg ',diag_temp
  diag_temp(:) = qfg(idjd,:)
  write(6,*) 'qfg ',diag_temp
end if
#endif

! First melt cloud ice or freeze cloud water to give correct ice fraction fice.
! Then calculate the cloud conserved variables qtot and tliq.
! Note that qcg is the total cloud water (liquid+frozen)

do k = 1,kl
  where ( ttg(:,k)>=tfrz )
    fice(:,k) = 0.
  elsewhere ( ttg(:,k)>=tice .and. qfg(:,k)>1.e-12 )
    fice(:,k) = min(qfg(:,k)/(qfg(:,k)+qlg(:,k)), 1.)
  elsewhere( ttg(:,k)>=tice )
    fice(:,k) = 0.
  elsewhere
    fice(:,k) = 1.
  end where
  qcg(:,k)   = qlg(:,k) + qfg(:,k)
  qcold(:,k) = qcg(:,k)
  qfnew(:,k) = fice(:,k)*qcg(:,k)
  ttg(:,k)   = ttg(:,k) + hlfcp*(qfnew(:,k)-qfg(:,k)) !Release L.H. of fusion
  qfg(:,k)   = qfnew(:,k)
  qlg(:,k)   = max(0., qcg(:,k)-qfg(:,k))
  qtot(:,k) = qtg(:,k) + qcg(:,k)
  tliq(:,k) = ttg(:,k) - hlcp*qcg(:,k) - hlfcp*qfg(:,k) 
end do

#ifndef GPU
if ( diag .and. mydiag ) then
  write(6,*) 'within newcloud'
  diag_temp = ttg(idjd,:)
  write(6,*) 'ttg ',diag_temp
  diag_temp = qcold(idjd,:)
  write(6,*) 'qcold ',diag_temp
  diag_temp = qcg(idjd,:)
  write(6,*) 'qcg ',diag_temp
  diag_temp = qlg(idjd,:)
  write(6,*) 'qlg ',diag_temp
  diag_temp = qfg(idjd,:)
  write(6,*) 'qfg ',diag_temp
  diag_temp = fice(idjd,:)
  write(6,*) 'fice ',diag_temp
end if
#endif


! Precompute the array of critical relative humidities 
if ( nclddia==-3 ) then
  do k = 1,kl
    where ( land(:) )
      rcrit(:,k)=max( rcrit_l, (1.-16.*(1.-sig(k))**3) )
    elsewhere
      rcrit(:,k)=max( rcrit_s, (1.-16.*(1.-sig(k))**3) )
    end where
  enddo
else if ( nclddia<0 ) then
  do k = 1,kl
    where ( land(:) )
      rcrit(:,k)=max( rcrit_l, (1.-4.*(1.-sig(k))**2) )
    elsewhere
      rcrit(:,k)=max( rcrit_s, (1.-4.*(1.-sig(k))**2) )
    end where
  enddo
else if ( nclddia==1 ) then
  do k = 1,kl
    where ( land(:) )
      rcrit(:,k)=max( rcrit_l, sig(k)**3 )
    elsewhere
      rcrit(:,k)=max( rcrit_s, sig(k)**3 )
    end where
  enddo
else if ( nclddia==2 ) then
  do k = 1,kl
    where ( land(:) )
      rcrit(:,k)=rcrit_l
    elsewhere
      rcrit(:,k)=rcrit_s
    end where
  enddo
else if ( nclddia==3 ) then
  do k = 1,kl
    where ( land(:) )
      rcrit(:,k)=max( rcrit_l, sig(k)**2 )          ! .75 for R21 Mk2
    elsewhere
      rcrit(:,k)=max( rcrit_s, sig(k)**2 )          ! .85 for R21 Mk2
    end where
  enddo
else if ( nclddia==4 ) then
  do k = 1,kl
    where ( land(:) )
      rcrit(:,k)=max( rcrit_l, sig(k) )             ! .75 for test Mk2/3
    elsewhere
      rcrit(:,k)=max( rcrit_s, sig(k) )             ! .9  for test Mk2/3
    end where
  enddo
else if ( nclddia==5 ) then  ! default till May 08
  do k = 1,kl
    where ( land(:) )
      rcrit(:,k)=max( rcrit_l, min(.99,sig(k)) )    ! .75 for same as T63
    elsewhere
      rcrit(:,k)=max( rcrit_s, min(.99,sig(k)) )    ! .85 for same as T63
    end where
  enddo
else if ( nclddia==6 ) then
  do k = 1,kl
    where ( land(:) )
      rcrit(:,k)=max(rcrit_l*(1.-.15*sig(k)),sig(k)**4)
    elsewhere
      rcrit(:,k)=max(rcrit_s*(1.-.15*sig(k)),sig(k)**4)
    end where
  enddo
else if ( nclddia==7 ) then
  do k = 1,kl
    where ( land(:) )
      rcrit(:,k)=max(rcrit_l*(1.-.2*sig(k)),sig(k)**4)
    elsewhere
      rcrit(:,k)=max(rcrit_s*(1.-.2*sig(k)),sig(k)**4)
    end where
  enddo
else if ( nclddia>7 ) then  ! e.g. 12    JLM
  ! MJT notes - Lopez (2002) "Implementation and validation of a new pronostic large-scale cloud
  ! and precipitation scheme for climate and data-assimilation purposes" Q J R Met Soc 128, 229-257,
  ! has a useful discussion of the dependence of RHcrit on grid spacing
  do k = 1,kl  ! typically set rcrit_l=.75,  rcrit_s=.85
    do iq = 1,imax
      tk(iq) = ds/(em(iq)*208498.) ! MJT suggestion
      fl(iq) = (1.+real(nclddia))*tk(iq)/(1.+real(nclddia)*tk(iq))
      ! for rcit_l=.75 & nclddia=12 get rcrit=(0.751, 0.769, .799, .901, .940, .972, .985) for (200, 100, 50, 10, 5, 2, 1) km
      if ( land(iq) ) then
        rcrit(iq,k) = max( 1.-fl(iq)*(1.-rcrit_l), sig(k)**3 )
      else
        rcrit(iq,k) = max( 1.-fl(iq)*(1.-rcrit_s), sig(k)**3 )
      end if
    end do
  end do
end if  ! (nclddia<0)  .. else ..


if ( ncloud<=3 ) then
  ! usual diagnostic cloud fraction
      
  ! Calculate cloudy fraction of grid box (stratcloud) and gridbox-mean cloud water
  ! using the triangular PDF of Smith (1990)

  do k = 1,kl
    hlrvap(:) = (hl+fice(:,k)*hlf)/rvap
    ! Calculate qs and gam=(L/cp)*dqsdt,  at temperature tliq
    pk(:) = 100.0*prf(:,k)
    qsi(:,k) = qsati(pk,tliq(:,k)) !Ice value
    deles(:) = esdiffx(tliq(:,k))  ! MJT suggestion
    qsl(:,k) = qsi(:,k) + epsil*deles/pk !qs over liquid
    qsw(:,k) = fice(:,k)*qsi(:,k) +    & 
                     (1.-fice(:,k))*qsl(:,k) !Weighted qs at temperature Tliq
    qs(:) = qsw(:,k)
    dqsdt(:) = qs*hlrvap(:)/tliq(:,k)**2
    al(:) = 1./(1.+(hlcp+fice(:,k)*hlfcp)*dqsdt)  !Smith's notation
    qc(:) = qtot(:,k) - qs
    delq(:) = (1.-rcrit(:,k))*qs     !UKMO style (equivalent to above)
    where ( qc(:)<=-delq(:) )
      stratcloud(:,k) = 0.
      qcg(:,k) = 0.
    else where ( qc(:)<=0. )
      stratcloud(:,k) = max( 1.e-6, 0.5*((qc+delq)/delq)**2 )  ! for roundoff
      qcg(:,k) = max( 1.e-8, al*(qc+delq)**3/(6.*delq**2) )    ! for roundoff
    else where ( qc(:)<delq(:) )
      stratcloud(:,k) = max( 1.e-6, 1.-0.5*((qc-delq)/delq)**2 ) ! for roundoff
      qcg(:,k) = max( 1.e-8, al*(qc-(qc-delq)**3/(6.*delq**2)) ) ! for roundoff
    else where
      stratcloud(:,k) = 1.
      qcg(:,k) = al*qc
    end where
    
  end do

#ifdef GPU
  if ( diag .and. mydiag ) then
    diag_temp(:) = rcrit(idjd,:)
    write(6,*) 'rcrit ',diag_temp
    diag_temp(:) = qtot(idjd,:)
    write(6,*) 'qtot ',diag_temp
    diag_temp(:) = qsi(idjd,:)
    write(6,*) 'qsi',diag_temp
    diag_temp(:) = tliq(idjd,:)
    write(6,*) 'tliq',diag_temp
    diag_temp(:) = qsl(idjd,:)
    write(6,*) 'qsl ',diag_temp
    diag_temp(:) = qsw(idjd,:)
    write(6,*) 'qsw ',diag_temp
    diag_temp(:) = stratcloud(idjd,:)
    write(6,*) 'stratcloud',diag_temp
    diag_temp(:) = qtot(idjd,:)-qsw(idjd,:)
    write(6,*) 'qc  ',diag_temp  
    diag_temp(:) = qcg(idjd,:)
    write(6,*) 'qcg ',diag_temp
    diag_temp(:) = (1.-rcrit(idjd,:))*qsw(idjd,:)
    write(6,*) 'delq ',diag_temp 
  endif
#endif

  ! Assume condensation or evaporation retains ice fraction fice.
  ! Introduce a time-decay factor for cirrus (as suggested by results of Khvorostyanov & Sassen,
  ! JAS, 55, 1822-1845, 1998). Their suggested range for the time constant is 0.5 to 2 hours.
  ! The grid-box-mean values of qtg and ttg are adjusted later on (below).
  decayfac = exp ( -tdt/7200. )      ! Try 2 hrs
  !decayfac = 0.                     ! Instant adjustment (old scheme)
  do k = 1,kl
    where( ttg(:,k)>=Tice )
      qfg(:,k) = fice(:,k)*qcg(:,k)
      qlg(:,k) = qcg(:,k) - qfg(:,k)
    elsewhere                                 ! Cirrus T range
      qfg(:,k) = qcold(:,k)*decayfac + qcg(:,k)*(1.-decayfac)
      qlg(:,k) = 0.
      qcg(:,k) = qfg(:,k)
    end where
  end do
  
else
  
  ! Tiedtke prognostic cloud fraction model
  ! MJT notes - we use ttg instead of tliq
  do k = 1,kl
    pk = 100.*prf(:,k)
    qsi(:,k) = qsati(pk,ttg(:,k)) ! Ice value
    deles = esdiffx(ttg(:,k))
    qsl(:,k) = qsi(:,k) + epsil*deles/pk ! Liquid value
    qsw(:,k) = fice(:,k)*qsi(:,k) + (1.-fice(:,k))*qsl(:,k)        ! Weighted qs at temperature Tliq
  end do
  
  call progcloud(tdt,qcg,qtot,prf,rhoa,fice,qsw,ttg,rcrit,  &
                 dpsldt,nettend,stratcloud,imax,kl)

  decayfac = exp ( -tdt/7200. )      ! Try 2 hrs
  !decayfac = 0.                     ! Instant adjustment (old scheme)
  do k = 1,kl
    where( ttg(:,k)>=Tice )
      qfg(:,k) = fice(:,k)*qcg(:,k)
      qlg(:,k) = qcg(:,k) - qfg(:,k)
    elsewhere                                 ! Cirrus T range
      qfg(:,k) = qcold(:,k)*decayfac + qcg(:,k)*(1.-decayfac)
      qlg(:,k) = 0.
      qcg(:,k) = qfg(:,k)
    end where
  end do  
  
end if ! ncloud<=3 ..else..


! Do the vapour deposition calculation in mixed-phase clouds:
! Calculate deposition on cloud ice, assuming es(T) is the weighted value of the 
! liquid and ice values.
pk(:) = 1.e5 ! default
Tk(:) = 300. ! default
do k = 1,kl  
  where ( stratcloud(:,k)>0. )
    Tk(:) = tliq(:,k) + hlcp*(qlg(:,k)+qfg(:,k))/stratcloud(:,k) !T in liq cloud
    !fl(:) = qlg(:,k)/max(qfg(:,k)+qlg(:,k),1.e-30)
  end where
!dir$ ivdep
  do iq = 1,imax
    if ( stratcloud(iq,k)>0. .and. Tk(iq)<tfrz .and. qlg(iq,k)>1.e-8 ) then
      pk(iq)    = 100.*prf(iq,k)
      qs(iq)    = qsati(pk(iq),Tk(iq))
      es        = qs(iq)*pk(iq)/0.622 !ice value
      Aprpr     = hl/(rKa*Tk(iq))*(hls/(rvap*Tk(iq))-1.)
      Bprpr     = rvap*Tk(iq)/((Dva/pk(iq))*es)
      deles(iq) = (1.-fice(iq,k))*esdiffx(Tk(iq))
      Cice      = 1.e3*exp(12.96*deles(iq)/es - 0.639) !Meyers et al 1992
      qi0       = cm0*Cice/rhoa(iq,k) !Initial ice mixing ratio
      ! Next 2 lines are for assumption of fully mixed ql and qf (also a line further down).
      qi0       = max(qi0, qfg(iq,k)/stratcloud(iq,k)) !Assume all qf and ql are mixed
      fd        = 1.       !Fraction of cloud in which deposition occurs
      !fd        = fl(iq)   !Or, use option of adjacent ql,qf
      Crate     = 7.8*((Cice/rhoa(iq,k))**2/rhoic)**(1./3.)*deles(iq)/((Aprpr+Bprpr)*es)
      qfdep     = fd*stratcloud(iq,k)*sqrt(((2./3.)*Crate*tdt+qi0**(2./3.))**3)
      ! Also need this line for fully-mixed option...
      qfdep     = qfdep - qfg(iq,k)
      qfdep      = min(qfdep, qlg(iq,k))
      qlg(iq,k) = qlg(iq,k) - qfdep
      qfg(iq,k) = qfg(iq,k) + qfdep
    end if
  end do
  !fice(:,k) = qfg(:,k)/max(qfg(:,k)+qlg(:,k),1.e-30)
end do    

! Calculate new values of vapour mixing ratio and temperature
do k = 1,kl
  qtg(:,k) = qtot(:,k) - qcg(:,k)
  ttg(:,k) = tliq(:,k) + hlcp*qcg(:,k) + hlfcp*qfg(:,k)
end do

#ifndef GPU
if ( diag .and. mydiag ) then
   write(6,*) 'at end of newcloud'
   diag_temp(:) = ttg(idjd,:)
   write(6,*) 'ttg ',diag_temp
   diag_temp(:) = qcg(idjd,:)
   write(6,*) 'qcg ',diag_temp
   diag_temp(:) = qlg(idjd,:)
   write(6,*) 'qlg ',diag_temp
   diag_temp(:) = qfg(idjd,:)
   write(6,*) 'qfg ',diag_temp
   diag_temp(:) = qtg(idjd,:)
   write(6,*) 'qtg ',diag_temp
end if
#endif

return
end subroutine newcloud

 
! This routine is part of the prognostic cloud scheme. It calculates rainfall
! and the evaporation of rain, and also does the frozen precipitation. It is
! called by progcld.
!
! INPUT/OUTPUT
!
! Input:
!
! from arguments
!      tdt - leapfrog timestep (seconds)
!      rhoa - air density (kg/m**3)
!      dz - layer thicknes (m)
!      prf - pressure at full levels (in hPa. NB: not SI units)
!
! In/Out:
!
! from arguments
!      ttg - temperature (K)
!      qlg - cloud liquid water mixing ratio (kg/kg)
!      qfg - cloud ice mixing ratio (kg/kg)
!      qrg - falling rain (kg/kg)
!      qsng - falling snow (kg/kg)
!      qgrg - falling graupel (kg/kg)
!      precs - amount of stratiform precipitation in timestep (mm)
!      qtg - water vapour mixing ratio (kg/kg) - called qg in C-CAM
!      stratcloud - stratiform cloud fraction
!      cfrain - falling rain fraction
!      cfsnow - falling snow fraction
!      cfgraupel - falling graupel fraction
!
! Output:
!
! from arguments
!      preci - amount of stratiform snowfall in timestep (mm)
!      precg - amount of stratiform graupel in timestep (mm)
!      qevap - evaporation of rainfall (kg/kg)
!      qsubl - sublimation of snowfall (kg/kg)
!      qauto - autoconversion of cloud liquid water (kg/kg)
!      qcoll - collection by rain of cloud liquid water (kg/kg)
!      qaccr - accretion by snow of cloud liquid water (kg/kg)
!
!**************************************************************************

subroutine newsnowrain(tdt_in,rhoa,dz,prf,cdrop,ttg,qlg,qfg,qrg,qsng,qgrg,precs,qtg,stratcloud,cfrain,    &
                       cfsnow,cfgraupel,preci,precg,qevap,qsubl,qauto,qcoll,qaccr,qaccf,fluxr,            &
                       fluxi,fluxs,fluxg,fluxm,fluxf,pfstayice,pfstayliq,pqfsedice,pslopes,prscav,        &
                       condx,ktsav,idjd,mydiag,ncloud,nevapls,ldr,rcm,imax,kl)
!$acc routine vector

use const_phys                    ! Physical constants
use estab                         ! Liquid saturation function
use parm_m, only : diag, nmr, nmaxpr
                                  ! Model configuration

implicit none

integer, intent(in) :: idjd, ncloud, nevapls, ldr
integer, intent(in) :: imax, kl
real, intent(in) :: tdt_in
real, dimension(imax,kl), intent(in) :: rhoa
real, dimension(imax,kl), intent(in) :: dz
real, dimension(imax,kl), intent(in) :: prf
real, dimension(imax,kl), intent(in) :: cdrop
real, dimension(imax,kl), intent(inout) :: ttg
real, dimension(imax,kl), intent(inout) :: qlg
real, dimension(imax,kl), intent(inout) :: qfg
real, dimension(imax,kl), intent(inout) :: qrg
real, dimension(imax,kl), intent(inout) :: qsng
real, dimension(imax,kl), intent(inout) :: qgrg
real, dimension(imax,kl), intent(inout) :: qtg
real, dimension(imax,kl), intent(inout) :: stratcloud
real, dimension(imax,kl), intent(inout) :: cfrain
real, dimension(imax,kl), intent(inout) :: cfsnow
real, dimension(imax,kl), intent(inout) :: cfgraupel
real, dimension(imax,kl), intent(out) :: qevap
real, dimension(imax,kl), intent(out) :: qsubl
real, dimension(imax,kl), intent(out) :: qauto
real, dimension(imax,kl), intent(out) :: qcoll
real, dimension(imax,kl), intent(out) :: qaccr
real, dimension(imax,kl), intent(out) :: qaccf
real, dimension(imax,kl), intent(out) :: pqfsedice
real, dimension(imax,kl), intent(out) :: pfstayice
real, dimension(imax,kl), intent(out) :: pfstayliq
real, dimension(imax,kl), intent(out) :: pslopes
real, dimension(imax,kl), intent(out) :: prscav
real, dimension(imax,kl), intent(out) :: fluxr
real, dimension(imax,kl), intent(out) :: fluxi
real, dimension(imax,kl), intent(out) :: fluxs
real, dimension(imax,kl), intent(out) :: fluxg
real, dimension(imax,kl), intent(out) :: fluxm
real, dimension(imax,kl), intent(out) :: fluxf
real, dimension(imax), intent(in) :: condx
real, dimension(imax), intent(inout) :: precs
real, dimension(imax), intent(inout) :: preci
real, dimension(imax), intent(inout) :: precg
real, intent(in) :: rcm
integer, dimension(imax), intent(in) :: ktsav
logical, intent(in) :: mydiag

real, dimension(imax,kl) :: fluxautorain, fluxautosnow, fluxautograupel
real, dimension(imax,kl) :: cfautorain, cfautosnow, cfautograupel
real, dimension(imax,kl) :: rhov, rhol, rhoi, rhos, rhog, rhor
real, dimension(imax,kl) :: clfr,cifr,qsatg
real, dimension(imax) :: fthruliq,foutliq,fthruice,foutice
real, dimension(imax) :: fthrusnow,foutsnow,fthrugraupel,foutgraupel
real, dimension(imax) :: vi2, vr2, vs2, vg2
real, dimension(imax) :: fluxice,fluxsnow,fluxgraupel,fluxrain
real, dimension(imax) :: rhoiin,rhoiout,rhorin,rhorout
real, dimension(imax) :: rhosin,rhosout,rhogin,rhogout
real, dimension(imax) :: cffluxin,cffluxout
real, dimension(imax) :: crfra,cifra,csfra,cgfra
real, dimension(imax) :: mxclfrrain,rdclfrrain,mxclfrice,rdclfrice
real, dimension(imax) :: mxclfrsnow,rdclfrsnow,mxclfrgraupel,rdclfrgraupel
real, dimension(imax) :: frclr
real :: rg, rl, rn, rf, rs
real, dimension(imax) :: sublflux
real, dimension(imax) :: rhodz,evap,qpf,clrevap,fr
real, dimension(imax) :: fcol
real :: alph
real, dimension(imax) :: alphaf,pk,aprpr,bprpr
real, dimension(imax) :: curly,Csbsav
real :: n0s
real, dimension(imax) :: cfmelt, fluxmelt, fluxfreeze
real :: slopes_g, slopes_s, xwgt
real, dimension(imax) :: denfac, qsl
real, dimension(imax) :: xfrac_graupel, xfrac_snow, xfrac_ice
real, dimension(imax) :: rhototf
real, dimension(imax) :: gam1
real, dimension(kl) :: diag_temp

integer k, n, njumps, iq
real scm3, tdt
real qcrit, qcic, ql, dqls, Crate, ql1, ql2
real Frb, cdts, selfcoll
real qfs, dqfs
real fsclr_g, fsclr_s, fsclr_i
real qvp, iflux, lflux
real drf, drl
real dqf, dqs, dql
real cdt, dttg, csb, bf
real qrn, qsn, qif, qf
real coll
real es
real cftmp, cltmp
real slopes_r, slopes_i
real esi, apr, bpr, cev
real dqsdt, bl, satevap

real, parameter :: n0r = 8.e6        ! intercept for rain
real, parameter :: n0g = 4.e6        ! intercept for graupel
real, parameter :: rho_r = 1.0e3     ! rain density
real, parameter :: rho_s = 0.1e3     ! snow density
real, parameter :: rho_g = 0.4e3     ! grauple density
real, parameter :: qr0_crt = 2.e-4   ! rain -> snow or graupel density threshold
real, parameter :: qi0_crt = 8.e-5   ! ice -> snow density threshold
real, parameter :: qs0_crt = 6.e-3   ! snow -> graupel density threshold
real, parameter :: c_piacr = 0.1     ! accretion rate of rain -> ice
real, parameter :: c_psaut = 1.e-3   ! autoconversion rate of ice -> snow
!real, parameter :: c_pgacs = 1.e-3  ! snow -> graupel "accretion" eff
real, parameter :: sfcrho = 1.2      ! reference density rho_0
real, parameter :: vdifu = 2.11e-5
real, parameter :: tcond = 2.36e-2
real, parameter :: visk = 1.259e-5
real, parameter :: gam263 = 1.456943 ! gamma function for 2.63
real, parameter :: gam275 = 1.608355 ! gamma function for 2.75
real, parameter :: gam325 = 2.54925  ! gamma function for 3.25
real, parameter :: gam350 = 3.323363 ! gamma function for 3.5
real, parameter :: gam380 = 4.694155 ! gamma function for 3.8
real, parameter :: alin = 842.
real, parameter :: clin = 4.8
real, parameter :: gcon = 44.628 ! = 40.74*sqrt(sfcrho)
!real, parameter :: tau_s = 90.   ! (sec) snow melt
!real, parameter :: tau_g = 180.  ! (sec) graupel melt

scm3 = (visk/vdifu)**(1./3.)

do k = 1,kl
  fluxr(:,k)           = 0.
  fluxi(:,k)           = 0.
  fluxs(:,k)           = 0.
  fluxg(:,k)           = 0. 
  fluxm(:,k)           = 0.  
  fluxf(:,k)           = 0.
  fluxautorain(:,k)    = 0.
  fluxautosnow(:,k)    = 0.
  fluxautograupel(:,k) = 0.
  qevap(:,k)           = 0.
  qauto(:,k)           = 0.
  qcoll(:,k)           = 0.
  qsubl(:,k)           = 0.
  qaccr(:,k)           = 0.
  qaccf(:,k)           = 0.
  pqfsedice(:,k)       = 0.
  prscav(:,k)          = 0.  
  pfstayice(:,k)       = 0.  
  pfstayliq(:,k)       = 0. 
  pslopes(:,k)         = 0.
  pk(:)                = 100.*prf(:,k)
  qsatg(:,k)           = qsati(pk(:),ttg(:,k))
  cifr(:,k)            = qfg(:,k)*stratcloud(:,k)/max( qlg(:,k)+qfg(:,k), 1.e-30 )
  clfr(:,k)            = qlg(:,k)*stratcloud(:,k)/max( qlg(:,k)+qfg(:,k), 1.e-30 )
  cfautorain(:,k)      = 0.
  cfautosnow(:,k)      = 0.
  cfautograupel(:,k)   = 0.
end do

! Use full timestep for autoconversion
!njumps = 1
tdt = tdt_in

do k = kl-1,1,-1
  do iq = 1,imax
    if ( clfr(iq,k)>0. ) then
      qcrit = (4.*pi/3.)*rhow*Rcm**3*cdrop(iq,k)/rhoa(iq,k)
      qcic  = qlg(iq,k)/clfr(iq,k) !In cloud value
      if ( qcic>=qcrit ) then
        Crate    = Aurate*rhoa(iq,k)*(rhoa(iq,k)/(cdrop(iq,k)*rhow))**(1./3.)
        ql1      = 1./pow75(qcic**(-4./3.)+(4./3.)*Crate*tdt)
        ql1      = max( ql1, qcrit ) !Intermediate qlg after auto
        Frb      = dz(iq,k)*rhoa(iq,k)*(qcic-ql1)/tdt
        Frb      = min( Frb, 1.e10 ) ! prevent overflow
        cdts     = tdt*0.5*Ecol*0.24*pow75(Frb) ! old
        selfcoll = min( ql1, ql1*cdts )
        ql2      = ql1 - selfcoll
        ql       = clfr(iq,k)*ql2
        dqls     = max( qlg(iq,k)-ql, 0. )
        cfautorain(iq,k) = clfr(iq,k)
        qauto(iq,k)      = qauto(iq,k) + dqls
        qlg(iq,k)        = qlg(iq,k)   - dqls
        fluxautorain(iq,k) = dqls*rhoa(iq,k)*dz(iq,k)
      end if
    end if
  end do
end do  

! calculate rate of precipitation of frozen cloud water to snow
if ( ncloud>=3 ) then

  do k = 1,kl
    do iq = 1,imax
      
      ! autoconversion of ice to snow (from Lin et al 1983)
      ! Threshold from WSM6 scheme, Hong et al 2004, Eq(13) : qi0_crt ~8.e-5
      if ( qfg(iq,k)*rhoa(iq,k)>qi0_crt ) then
        qfs  = max( qfg(iq,k)-qi0_crt/rhoa(iq,k), 0. )
        cdts = tdt*c_psaut*exp(0.025*(ttg(iq,k)-tfrz))
        dqfs = max( min( qfg(iq,k), qfs*cdts ), 0. )
        cfautosnow(iq,k)   = cifr(iq,k)
        qfg(iq,k)          = qfg(iq,k) - dqfs
        fluxautosnow(iq,k) = dqfs*rhoa(iq,k)*dz(iq,k)
      end if
    
      ! autoconversion of snow to graupel (from Lin et al 1983)
      if ( qsng(iq,k)*rhoa(iq,k)>qs0_crt ) then
        qfs  = max( qsng(iq,k)-qs0_crt/rhoa(iq,k), 0. )
        cdts = tdt*1.e-3*exp(0.09*(ttg(iq,k)-tfrz))
        dqfs = max( min( qsng(iq,k), qfs*cdts ), 0.) 
        cfautograupel(iq,k)   = cfsnow(iq,k)
        qsng(iq,k)            = qsng(iq,k) - dqfs
        fluxautograupel(iq,k) = dqfs*rhoa(iq,k)*dz(iq,k)
      end if

    end do  
  end do
  
end if ! ( ncloud>=3 )

! update density and area fractions
do k = 1,kl
  cifr(:,k) = stratcloud(:,k)*qfg(:,k)/max(qlg(:,k)+qfg(:,k),1.e-30 )
  clfr(:,k) = max( stratcloud(:,k)-cifr(:,k), 0. )
  rhov(:,k) = qtg(:,k)*rhoa(:,k)
  rhoi(:,k) = qfg(:,k)*rhoa(:,k)
  rhol(:,k) = qlg(:,k)*rhoa(:,k)
  rhor(:,k) = qrg(:,k)*rhoa(:,k)
  rhos(:,k) = qsng(:,k)*rhoa(:,k)
  rhog(:,k) = qgrg(:,k)*rhoa(:,k)
end do


#ifndef GPU
if ( diag .and. mydiag ) then
  diag_temp(:) = stratcloud(idjd,:)
  write(6,*) 'stratcloud',diag_temp
  diag_temp(:) = cifr(idjd,:)
  write(6,*) 'cifr      ',diag_temp
  diag_temp(:) = clfr(idjd,:)
  write(6,*) 'clfr      ',diag_temp
  diag_temp(:) = cfrain(idjd,:)
  write(6,*) 'cfrain    ',diag_temp
  diag_temp(:) = cfsnow(idjd,:)
  write(6,*) 'cfsnow    ',diag_temp
  diag_temp(:) = cfgraupel(idjd,:) 
  write(6,*) 'cfgraupel ',diag_temp
  diag_temp(:) = qlg(idjd,:) 
  write(6,*) 'qlg ',diag_temp
  diag_temp(:) = qfg(idjd,:)
  write(6,*) 'qfg ',diag_temp
  diag_temp(:) = qrg(idjd,:)
  write(6,*) 'qrg ',diag_temp
  diag_temp(:) = qsng(idjd,:)
  write(6,*) 'qsng',diag_temp
  diag_temp(:) = qgrg(idjd,:)
  write(6,*) 'qgrg',diag_temp
endif  ! (diag.and.mydiag)
#endif


! Use sub time-step if required
if ( ncloud>=3 ) then
  njumps = int(tdt_in/(maxlintime+0.01)) + 1
  tdt    = tdt_in/real(njumps)
else
  njumps = 1
  tdt = tdt_in
end if

do n = 1,njumps

  fluxgraupel(:)   = 0.
  mxclfrgraupel(:) = 0. ! max overlap graupel fraction
  rdclfrgraupel(:) = 0. ! rnd overlap graupel fraction
  cgfra(:)         = 0. ! total graupel fraction = mx+rd-mx*rd
  vg2(:)           = 0.1

  fluxsnow(:)   = 0.
  mxclfrsnow(:) = 0. ! max overlap snow fraction
  rdclfrsnow(:) = 0. ! rnd overlap snow fraction
  csfra(:)      = 0. ! total snow fraction = mx+rd-mx*rd
  vs2(:)        = 0.1

  fluxice(:)   = 0.
  mxclfrice(:) = 0. ! max overlap ice fraction
  rdclfrice(:) = 0. ! rnd overlap ice fraction
  cifra(:)     = 0. ! total ice fraction = mx+rd-mx*rd 
  vi2(:)       = 0.1 ! Assume no cloud at top level

  fluxrain(:)   = 0.
  mxclfrrain(:) = 0. ! max overlap rain fraction
  rdclfrrain(:) = 0. ! rnd overlap rain fraction
  crfra(:)      = 1.e-6 ! total rain fraction = mx+rd-mx*rd
  vr2(:)        = 0.


  ! Now work down through the levels...
  do k = kl-1,1,-1
  
    ! misc fields
    do iq = 1,imax
      pk(iq)     = 100.*prf(iq,k)
      rhodz(iq)  = rhoa(iq,k)*dz(iq,k)
      denfac(iq) = sqrt(sfcrho/rhoa(iq,k))
      fluxmelt(iq)   = 0.
      fluxfreeze(iq) = 0.
      cfmelt(iq)     = 0.
    end do
    
    if ( ncloud>=3 ) then
  
      ! Graupel ---------------------------------------------------------------------------
      sublflux(:) = 0.
    
      fluxgraupel(:) = fluxgraupel + fluxautograupel(:,k)*tdt/tdt_in
      
      ! Detect max/random overlap clouds that are separated by a clear layer
      where ( (stratcloud(:,k)>=1.e-10.and.stratcloud(:,k+1)<1.e-10) .or. nmr==0 )
        rdclfrgraupel(:) = rdclfrgraupel + mxclfrgraupel - rdclfrgraupel*mxclfrgraupel
        mxclfrgraupel(:) = 0.
      end where
      cgfra(:) = max( rdclfrgraupel + mxclfrgraupel - rdclfrgraupel*mxclfrgraupel, 1.e-15 )
       
      ! graupel fall speed (from Lin et al 1983 - see GFDL AM3)
      do iq = 1,imax
        rg = max( fluxgraupel(iq)/dz(iq,k), 0. )
        if ( cgfra(iq)>=1.e-10 ) then
          vg2(iq) = max( 0.1, 5.34623815*(rg/cgfra(iq))**0.125 )
        end if
      end do

      ! Set up the parameters for the flux-divergence calculation
      do iq = 1,imax
        alph         = tdt*vg2(iq)/dz(iq,k)
        foutgraupel(iq)  = 1. - exp(-alph)        !analytical
        fthrugraupel(iq) = 1. - foutgraupel(iq)/alph  !analytical
      end do
      
      if ( any( fluxgraupel>0. ) ) then

        alphaf(:) = hls*qsatg(:,k)/(rvap*ttg(:,k)**2)
        gam1(:)   = hlscp*alphaf !(L/cp)*dqsdt (HBG notation)
      
        ! Melt falling graupel (based on Lin et al 83)
        do iq = 1,imax
          rg = max(fluxgraupel(iq), 0.)/dz(iq,k)
          if ( ttg(iq,k)>tfrz .and. rg>1.e-15 ) then
            slopes_g          = ( max( fluxgraupel(iq), 0. )/dz(iq,k)/(pi*n0g*rho_g))**0.25
            qvp               = rhov(iq,k)/rhoa(iq,k)
            cdt               = tdt*2.*pi*n0g/hlf*(tcond*(ttg(iq,k)-tfrz)/rhoa(iq,k)-vdifu*hl*(qsatg(iq,k)-qvp))              &
                               *(0.78*slopes_g**2+0.31*scm3*gam275*sqrt(gcon/visk)*slopes_g**2.75*sqrt(denfac(iq)))
            drf               = max( min( rg, cdt ), 0. )
            iflux             = min( drf*dz(iq,k), fluxgraupel(iq) ) ! flux of graupel
            drf               = iflux/dz(iq,k)                   ! mass of graupel
            dqf               = drf/rhoa(iq,k)                   ! mixing ratio of graupel
            fluxmelt(iq)      = fluxmelt(iq)    + iflux
            fluxgraupel(iq)   = fluxgraupel(iq) - iflux
            dttg              = -hlfcp*dqf
            ttg(iq,k)         = ttg(iq,k) + dttg
            qsatg(iq,k)       = qsatg(iq,k) + gam1(iq)*dttg/hlscp
            rdclfrgraupel(iq) = rdclfrgraupel(iq)*(1.-drf/rg)
            mxclfrgraupel(iq) = mxclfrgraupel(iq)*(1.-drf/rg)
            cftmp             = mxclfrgraupel(iq) + rdclfrgraupel(iq) - mxclfrgraupel(iq)*rdclfrgraupel(iq)
            cfmelt(iq)        = max( cfmelt(iq), max(cgfra(iq)-cftmp,0.) )
            cgfra(iq)         = cftmp
          end if
        end do
        
        ! Sublimation of graupel is neglected in the UM and ACCESS 1.3.
        ! (Currently treated the same as LDR97 ice sublimation)
        do iq = 1,imax
          qvp = rhov(iq,k)/rhoa(iq,k)
          if ( fluxgraupel(iq)>0. .and. qvp<qsatg(iq,k) ) then ! sublime graupel
            slopes_g        = ( max(fluxgraupel(iq),0.)/dz(iq,k)/(pi*n0g*rho_g))**0.25
            fsclr_g         = max( (1.-cifr(iq,k)-clfr(iq,k))*fluxgraupel(iq), 0. )  
            cdt             = 2.*pi*vdifu*tcond*rvap*n0g*ttg(iq,k)**2                                                    &
                             *(0.78*slopes_g**2+0.31*scm3*gam275*sqrt(gcon/visk)*slopes_g**2.75*sqrt(denfac(iq))) &
                             /(tcond*rvap*ttg(iq,k)**2+hls**2*vdifu*qsatg(iq,k)*rhoa(iq,k))
            dqs             = tdt*cdt*(qsatg(iq,k)-qvp)
            dqs             = min( dqs, (qsatg(iq,k)-qvp)/(1.+gam1(iq)) ) !Don't supersat.
            sublflux(iq)    = min( dqs*rhodz(iq), fsclr_g ) ! flux of graupel
            drf             = sublflux(iq)/dz(iq,k)          ! mass of graupel
            dqs             = drf/rhoa(iq,k)             ! mixing ratio of graupel
            fluxgraupel(iq) = fluxgraupel(iq) - sublflux(iq)
            fsclr_g         = fsclr_g     - sublflux(iq)
            rhov(iq,k)      = rhov(iq,k)  + drf        
            qsubl(iq,k)     = qsubl(iq,k) + dqs
            dttg            = -hlscp*dqs
            ttg(iq,k)       = ttg(iq,k) + dttg
            qsatg(iq,k)     = qsatg(iq,k) + gam1(iq)*dttg/hlscp
          end if
        end do
        
        ! Accretion of cloud liquid by falling graupel (from Lin et al 1983 - pgacw)
        ! This calculation uses the incoming fluxgraupel without subtracting sublimation
        ! (since subl occurs only outside cloud), so add sublflux back to fluxgraupel.
        do iq = 1,imax
          rl = rhol(iq,k)
          if ( fluxgraupel(iq)+sublflux(iq)>0. .and. rl>1.e-15 .and. ttg(iq,k)<tfrz ) then
            slopes_g        = ( max(fluxgraupel(iq)+sublflux(iq),0.)/dz(iq,k)/(pi*n0g*rho_g))**0.25
            cdt             = tdt*pi*n0g*gam350*gcon/4.0*slopes_g**3.5/sqrt(rhoa(iq,k))
            drl             = max( min( cgfra(iq)*rl, rl*cdt/(1.+0.5*cdt) ), 0. ) ! mass of liquid
            lflux           = drl*dz(iq,k)           ! flux of liquid
            dql             = drl/rhoa(iq,k)         ! mixing ratio of liquid
            fluxgraupel(iq) = fluxgraupel(iq) + lflux        
            rhol(iq,k)      = rhol(iq,k) - drl
            qaccr(iq,k)     = qaccr(iq,k) + dql
            dttg            = hlfcp*dql
            ttg(iq,k)       = ttg(iq,k) + dttg
            qsatg(iq,k)     = qsatg(iq,k) + gam1(iq)*dttg/hlscp
            cftmp           = clfr(iq,k)*drl/rl
            clfr(iq,k)      = clfr(iq,k) - cftmp
            mxclfrgraupel(iq) = max( mxclfrgraupel(iq), cftmp )
          end if
        end do
        
        ! Accretion of rain by falling graupel (from Lin et al 1983 - pgacr)
        ! (Neglected in UM and ACCESS 1.3)
        do iq = 1,imax
          rn = rhor(iq,k)
          if ( fluxgraupel(iq)+sublflux(iq)>0. .and. rn>1.e-15 .and. ttg(iq,k)<tfrz ) then
            slopes_g        = ( max( fluxgraupel(iq)+sublflux(iq), 0. )/dz(iq,k)/(pi*n0g*rho_g))**0.25
            slopes_r        = (( max( rn*dz(iq,k), 0. )/max( crfra(iq),1.e-15 )/tdt)**0.22)/714.        
            qrn             = rn/rhoa(iq,k)            
            cdt             = tdt*pi*pi*n0g*n0r*abs(vg2(iq)-vr2(iq))*qrn*(rho_r/rhoa(iq,k))   &
                             *(5.*slopes_r**6*slopes_g+2.*slopes_r**5*slopes_g**2      &
                             +0.5*slopes_r**4*slopes_g**3)          
            drl             = max( min( cgfra(iq)*rn, rn*cdt/(1.+0.5*cdt) ), 0. ) ! mass of rain
            lflux           = drl*dz(iq,k)   ! flux of rain
            dql             = drl/rhoa(iq,k) ! mixing ratio of rain
            fluxgraupel(iq) = fluxgraupel(iq) + lflux
            rhor(iq,k)      = rhor(iq,k) - drl
            dttg            = hlfcp*dql
            ttg(iq,k)       = ttg(iq,k) + dttg
            qsatg(iq,k)     = qsatg(iq,k) + gam1(iq)*dttg/hlscp 
            cftmp           = cfrain(iq,k)*drl/rn
            cfrain(iq,k)    = cfrain(iq,k) - cftmp
            mxclfrgraupel(iq) = max( mxclfrgraupel(iq), cftmp )
          end if
        end do  
        
        ! Accretion of cloud ice by falling graupel (from Lin et al 1983 - pgaci)
        ! (Neglected in UM and ACCESS 1.3)
        do iq = 1,imax
          rf = rhoi(iq,k)
          if ( fluxgraupel(iq)+sublflux(iq)>0. .and. rf>1.e-15 .and. ttg(iq,k)<tfrz ) then
            slopes_g        = ( max(fluxgraupel(iq)+sublflux(iq),0.)/dz(iq,k)/(pi*n0g*rho_g))**0.25
            cdt             = tdt*0.1*pi*n0g*gam350*gcon/4.*slopes_g**3.5/sqrt(rhoa(iq,k))
            drf             = max( min( cgfra(iq)*rf, rf*cdt/(1.+0.5*cdt) ), 0. ) ! mass of ice
            iflux           = drf*dz(iq,k)    ! flux of ice
            dqf             = drf/rhoa(iq,k)  ! mixing ratio of ice
            fluxgraupel(iq) = fluxgraupel(iq) + iflux
            rhoi(iq,k)      = rhoi(iq,k) - drf
            qaccf(iq,k)     = qaccf(iq,k) + dqf      
            cftmp           = cifr(iq,k)*drf/rf
            cifr(iq,k)      = cifr(iq,k) - cftmp
            mxclfrgraupel(iq) = max( mxclfrgraupel(iq), cftmp )
          end if
        end do
        
        ! Accretion of snow by falling graupel (from Lin et al 1983 - pgacs )
        do iq = 1,imax
          rs = rhos(iq,k)
          if ( fluxgraupel(iq)+sublflux(iq)>0. .and. rs>1.e-15 .and. ttg(iq,k)<tfrz ) then
            n0s             = 2.e6*exp(-0.12*max(ttg(iq,k)-tfrz,-200.))        
            slopes_s        = ( max(rs,0.)/(pi*rho_s*n0s))**0.25
            slopes_g        = ( max(fluxgraupel(iq)+sublflux(iq),0.)/dz(iq,k)/(pi*n0g*rho_g))**0.25
            qsn             = rs/rhoa(iq,k)  
            cdt             = tdt*pi*pi*n0g*n0s*abs(vg2(iq)-vs2(iq))*qsn*(rho_s/rhoa(iq,k))   &
                             *(5.*slopes_s**6*slopes_g+2.*slopes_s**5*slopes_g**2   &
                             +0.5*slopes_s**4*slopes_g**3)        
            drf             = max( min( cgfra(iq)*rs, rs*cdt/(1.+0.5*cdt) ), 0. ) ! mass of snow
            iflux           = drf*dz(iq,k)    ! flux of snow
            dqf             = drf/rhoa(iq,k)  ! mixing ratio of snow
            fluxgraupel(iq) = fluxgraupel(iq) + iflux
            rhos(iq,k)      = rhos(iq,k) - drf
            qaccf(iq,k)     = qaccf(iq,k) + dqf
            cftmp           = cfsnow(iq,k)*drf/rs
            cfsnow(iq,k)    = cfsnow(iq,k) - cftmp
            mxclfrgraupel(iq) = max( mxclfrgraupel(iq), cftmp )
          end if
        end do
        
      end if  

      
      ! Snow ------------------------------------------------------------------------------
      sublflux(:) = 0.
      
      fluxsnow(:) = fluxsnow + fluxautosnow(:,k)*tdt/tdt_in
      
      ! Detect max/random overlap clouds that are separated by a clear layer
      where ( (stratcloud(:,k)>=1.e-10.and.stratcloud(:,k+1)<1.e-10) .or. nmr==0 )
        rdclfrsnow(:) = rdclfrsnow + mxclfrsnow - rdclfrsnow*mxclfrsnow
        mxclfrsnow(:) = 0.
      end where
      csfra(:) = max( rdclfrsnow + mxclfrsnow - rdclfrsnow*mxclfrsnow, 1.e-15 )
  
      ! Snow fall speed (from Lin et al 1983 - see GFDL AM3)
      do iq = 1,imax
        rs = max( fluxsnow(iq)/dz(iq,k), 0. )
        if ( csfra(iq)>=1.e-10 ) then
          vs2(iq) = max( 0.1, 1.82*(rs/csfra(iq))**0.0625 )
        end if
      end do

      ! Set up the parameters for the flux-divergence calculation
      do iq = 1,imax
        alph          = tdt*vs2(iq)/dz(iq,k)
        foutsnow(iq)  = 1. - exp(-alph)          !analytical
        fthrusnow(iq) = 1. - foutsnow(iq)/alph  !analytical
      end do

      if ( any( fluxsnow>0. ) ) then

        alphaf(:) = hls*qsatg(:,k)/(rvap*ttg(:,k)**2)
        gam1(:)   = hlscp*alphaf(:) !(L/cp)*dqsdt (HBG notation)
          
        ! Melt falling snow if > 0 deg C due to rain accretion
        ! (based on Lin et al 83, but using 0.65 and 0.44 coeffs following the UM approach)
        do iq = 1,imax
          rs = max(fluxsnow(iq), 0.)/dz(iq,k)
          if ( ttg(iq,k)>tfrz .and. rs>1.e-15 ) then
            n0s            = 2.e6*exp(-0.12*max(ttg(iq,k)-tfrz,-200.))        
            slopes_s       = ( max(fluxsnow(iq),0.)/dz(iq,k)/(pi*rho_s*n0s))**0.25
            qvp            = rhov(iq,k)/rhoa(iq,k)  
            cdt            = tdt*2.*pi*n0s/hlf*(tcond*(ttg(iq,k)-tfrz)/rhoa(iq,k)-vdifu*hl*(qsatg(iq,k)-qvp))          &
                                     *(0.65*slopes_s**2+0.44*scm3*gam263*sqrt(clin/visk)*slopes_s**2.63*sqrt(denfac(iq)))
            drf            = max( min( rs, cdt ), 0. ) 
            iflux          = min( drf*dz(iq,k), fluxsnow(iq) )    ! flux of snow
            drf            = iflux/dz(iq,k)                      ! mass of snow
            dqf            = drf/rhoa(iq,k)                      ! mixing ratio of snow
            fluxmelt(iq)   = fluxmelt(iq) + iflux
            fluxsnow(iq)   = fluxsnow(iq) - iflux
            dttg           = -hlfcp*dqf
            ttg(iq,k)      = ttg(iq,k) + dttg
            qsatg(iq,k)    = qsatg(iq,k) + gam1(iq)*dttg/hlscp
            rdclfrsnow(iq) = rdclfrsnow(iq)*(1.-drf/rs)
            mxclfrsnow(iq) = mxclfrsnow(iq)*(1.-drf/rs)
            cftmp          = mxclfrsnow(iq) + rdclfrsnow(iq) - mxclfrsnow(iq)*rdclfrsnow(iq)
            cfmelt(iq)     = max( cfmelt(iq), max( csfra(iq)-cftmp, 0. ) )
            csfra(iq)      = cftmp      
          end if
        end do 
        
        ! Compute the sublimation of snow falling from level k+1 into level k
        ! (Currently treated the same as LDR97 ice sublimation - see UM and ACCESS 1.3)
        do iq = 1,imax
          qvp = rhov(iq,k)/rhoa(iq,k)
          if ( fluxsnow(iq)>0. .and. qvp<qsatg(iq,k) ) then ! sublime snow
            n0s          = 2.e6*exp(-0.12*max(ttg(iq,k)-tfrz,-200.))        
            slopes_s     = ( max(fluxsnow(iq),0.)/dz(iq,k)/(pi*rho_s*n0s))**0.25
            fsclr_s      = max( (1.-cifr(iq,k)-clfr(iq,k))*fluxsnow(iq), 0. )  
            cdt          = 2.*pi*vdifu*tcond*rvap*n0s*ttg(iq,k)**2                                                 &
                               *(0.65*slopes_s**2+0.44*scm3*gam263*sqrt(clin/visk)*slopes_s**2.63*sqrt(denfac(iq))) &
                               /(tcond*rvap*ttg(iq,k)**2+hls**2*vdifu*qsatg(iq,k)*rhoa(iq,k))
            dqs          = tdt*cdt*(qsatg(iq,k)-qvp)
            dqs          = min( dqs, (qsatg(iq,k)-qvp)/(1.+gam1(iq)) ) !Don't supersat.
            sublflux(iq) = min( dqs*rhodz(iq), fsclr_s ) ! flux of snow
            drf          = sublflux(iq)/dz(iq,k)                ! mass of snow
            dqs          = drf/rhoa(iq,k)                   ! mixing ratio of snow
            fluxsnow(iq) = fluxsnow(iq) - sublflux(iq)
            fsclr_s      = fsclr_s  - sublflux(iq)
            rhov(iq,k)   = rhov(iq,k)   + drf
            qsubl(iq,k)  = qsubl(iq,k)  + dqs
            dttg         = -hlscp*dqs
            ttg(iq,k)    = ttg(iq,k) + dttg
            qsatg(iq,k)  = qsatg(iq,k) + gam1(iq)*dttg/hlscp
          end if
        end do   
        
        ! Accretion of cloud liquid by falling snow (from Lin et al 1983 - psacw)
        do iq = 1,imax
          rl = rhol(iq,k)
          if ( fluxsnow(iq)+sublflux(iq)>0. .and. rl>1.e-15 .and. ttg(iq,k)<tfrz ) then
            n0s      = 2.e6*exp(-0.12*max(ttg(iq,k)-tfrz,-200.))        
            slopes_s = ( max(fluxsnow(iq)+sublflux(iq),0.)/dz(iq,k)/(pi*rho_s*n0s))**0.25
            cdt          = tdt*denfac(iq)*pi*clin*gam325*n0s/4.*slopes_s**3.25
            drl          = max( min( csfra(iq)*rl, rl*cdt/(1.+0.5*cdt) ), 0. ) ! mass of liquid
            lflux        = drl*dz(iq,k)                                                 ! flux of liquid
            dql          = drl/rhoa(iq,k)                                               ! mixing ratio of liquid
            fluxsnow(iq) = fluxsnow(iq) + lflux
            rhol(iq,k)   = rhol(iq,k)   - drl
            qaccr(iq,k)  = qaccr(iq,k)  + dql
            dttg         = hlfcp*dql
            ttg(iq,k)    = ttg(iq,k) + dttg
            qsatg(iq,k)  = qsatg(iq,k) + gam1(iq)*dttg/hlscp
            cftmp        = clfr(iq,k)*drl/rl
            clfr(iq,k)   = clfr(iq,k) - cftmp
            mxclfrsnow(iq) = max( mxclfrsnow(iq), cftmp )
          end if
        end do 
        
        ! Accretion of rain by falling snow to form snow (from Lin et al 1983 - psacr)
        do iq = 1,imax
          rn = rhor(iq,k)
          if ( fluxsnow(iq)+sublflux(iq)>0. .and. rn>1.e-15 .and. ttg(iq,k)<tfrz ) then
            n0s          = 2.e6*exp(-0.12*max(ttg(iq,k)-tfrz,-200.))        
            slopes_s     = ( max(fluxsnow(iq)+sublflux(iq),0.)/dz(iq,k)/(pi*rho_s*n0s))**0.25
            slopes_r     = (( max(rn*dz(iq,k),0.)/max(crfra(iq),1.e-15)/tdt)**0.22)/714.
            qrn          = rn/rhoa(iq,k)  
            cdt          = tdt*pi*pi*n0r*n0s*abs(vs2(iq)-vr2(iq))*qrn*(rho_r/rhoa(iq,k))         &
                                *(5.*slopes_r**6*slopes_s+2.*slopes_r**5*slopes_s**2  &
                                 +0.5*slopes_r**4*slopes_s**3)
            drl          = max( min( crfra(iq)*rn, rn*cdt/(1.+0.5*cdt) ), 0. ) ! mass of rain
            lflux        = drl*dz(iq,k)                                                 ! flux of rain
            dql          = drl/rhoa(iq,k)                                               ! mixing ratio of rain
            fluxsnow(iq) = fluxsnow(iq) + lflux
            rhor(iq,k)   = rhor(iq,k)   - drl
            dttg         = hlfcp*dql
            ttg(iq,k)    = ttg(iq,k) + dttg
            qsatg(iq,k)  = qsatg(iq,k) + gam1(iq)*dttg/hlscp  
            cftmp        = cfrain(iq,k)*drl/rn
            cfrain(iq,k) = cfrain(iq,k) - cftmp
            mxclfrsnow(iq) = max( mxclfrsnow(iq), cftmp )
          end if
        end do
        
        ! Accretion of rain by falling snow to form graupel (neglected in Lin83 but included in UM)   
    
        ! Accretion of cloud ice by falling snow (from HDC 2004 - psaci)
        do iq = 1,imax
          rf = rhoi(iq,k)
          if ( fluxsnow(iq)+sublflux(iq)>0. .and. rf>1.e-15 .and. ttg(iq,k)<tfrz ) then
            n0s          = 2.e6*exp(-0.12*max(ttg(iq,k)-tfrz,-200.))        
            slopes_s     = ( max(fluxsnow(iq)+sublflux(iq),0.)/dz(iq,k)/(pi*rho_s*n0s))**0.25
            esi          = exp(0.05*max(ttg(iq,k)-tfrz,-100.))       ! efficiency
            cdt          = tdt*denfac(iq)*27.737*n0s*esi*slopes_s**3.41
            drf          = max( min( csfra(iq)*rf, rf*cdt/(1.+0.5*cdt) ), 0. ) ! mass of ice
            iflux        = drf*dz(iq,k)                                                 ! flux of ice
            dqf          = drf/rhoa(iq,k)                                               ! mixing ratio of ice
            fluxsnow(iq) = fluxsnow(iq) + iflux
            rhoi(iq,k)   = rhoi(iq,k)   - drf
            qaccf(iq,k)  = qaccf(iq,k)  + dqf
            cftmp        = cifr(iq,k)*drf/rf
            cifr(iq,k)   = cifr(iq,k) - cftmp
            mxclfrsnow(iq) = max( mxclfrsnow(iq), cftmp )
          end if
        end do
        
      end if  
      
    end if

  
    ! Ice ---------------------------------------------------------------------------------
    sublflux(:) = 0.
   
    ! Set up the rate constant for ice sublimation
    ! MJT notes - curly and Csbsav depend on vi2(:,k+1), so vi2(:,k) can be updated below
    do iq = 1,imax
      slopes_i = 1.6e3*10**(-0.023*(ttg(iq,k)-tfrz))
      es = qsatg(iq,k)*pk(iq)/epsil
      Aprpr(iq) = (hls/(rKa*ttg(iq,k)))*(hls/(rvap*ttg(iq,k))-1.)
      Bprpr(iq) = rvap*ttg(iq,k)/((Dva/pk(iq))*es)
      if ( nevapls==-1 .or. (nevapls==-2.and.condx(iq)>0..and.k<=ktsav(iq)) ) then
        curly(iq) = 0.
      else
        curly(iq) = 0.65*slopes_i**2+0.493*slopes_i*sqrt(slopes_i*vi2(iq)*rhoa(iq,k)/um) !Factor in curly brackets
      end if
    end do
    ! Define the rate constant for sublimation of snow, omitting factor rhoi
    Csbsav(:) = 4.*curly(:)/(rhoa(:,k)*qsatg(:,k)*(Aprpr(:)+Bprpr(:))*pi*vi2*rho_s)
    
    ! Detect max/random overlap clouds that are separated by a clear layer
    where ( (stratcloud(:,k)>=1.e-10.and.stratcloud(:,k+1)<1.e-10) .or. nmr==0 )
      rdclfrice(:) = rdclfrice + mxclfrice - rdclfrice*mxclfrice
      mxclfrice(:) = 0.
    end where
    cifra(:) = max( rdclfrice + mxclfrice - rdclfrice*mxclfrice, 1.e-15 )
  
    ! Set up snow fall speed field
    select case(abs(ldr))
      case(1)
        where ( cifr(:,k)>=1.e-10 )
          vi2(:) = max( 0.1, 3.23*(max(rhoi(:,k),0.)/cifr(:,k))**0.17 )  ! Ice fall speed from LDR 1997
        end where
      case(2)
        where ( cifr(:,k)>=1.e-10 )
          vi2(:) = 0.9*3.23*(rhoi(:,k)/cifr(:,k))**0.17
        end where
      case(3)
        where ( cifr(:,k)>=1.e-10 )
          vi2(:) = max( 0.1, 2.05+0.35*log10(rhoi(:,k)/rhoa(:,k)/cifr(:,k)) )
        end where
      case(4)
        where ( cifr(:,k)>=1.e-10 )
          vi2(:) = 1.4*3.23*(rhoi(:,k)/cifr(:,k))**0.17
        end where
      case(5)
        where ( cifr(:,k)>=1.e-10 )  
          vi2(:) = max( 0.1, 3.29*(max( rhoi(:,k), 0. )/cifr(:,k))**0.16 ) ! from Lin et al 1983 
        end where  
      case(11)
        ! following are alternative slightly-different versions of above
        ! used for I runs from 29/4/05 till 30/8/05
        ! for given qfg, large cifr implies small ice crystals, 
        ! with a small fall speed. 
        ! Note that for very small qfg, cifr is small.
        ! But rhoi is like qfg, so ratio should also be small and OK.
        vi2(:) = max( vi2(:), 3.23*(rhoi(:,k)/max(cifr(:,k),1.e-30))**0.17 )
      case(22)
        vi2(:) = max( vi2(:), 0.9*3.23*(rhoi(:,k)/max(cifr(:,k),1.e-30))**0.17 )
      case(33)
        ! following max gives vi2=.1 for qfg=cifr=0
        vi2(:) = max( vi2(:), 2.05+0.35*log10(max(rhoi(:,k)/rhoa(:,k),2.68e-36)/max(cifr(:,k),1.e-30)) )
      case(55)
        vi2(:) = max( vi2(:), 3.29*(max(rhoi(:,k),0.)/cifr(:,k))**0.16 ) ! from Lin et al 1983   
    end select

    vi2 = max( vi2, 0.001 )  
      
    ! Set up the parameters for the flux-divergence calculation
    do iq = 1,imax
      alph         = tdt*vi2(iq)/dz(iq,k)
      foutice(iq)  = 1. - exp(-alph)    !analytical
      fthruice(iq) = 1. - foutice(iq)/alph  !analytical  
    end do

    if ( any( fluxice>0. ) ) then

      alphaf(:) = hls*qsatg(:,k)/(rvap*ttg(:,k)**2)
      gam1(:)   = hlscp*alphaf !(L/cp)*dqsdt (HBG notation)
        
      ! Melt falling ice if > 0 deg C
      do iq = 1,imax
        if ( ttg(iq,k)>tfrz .and. fluxice(iq)>0. ) then
          qif           = fluxice(iq)/rhodz(iq)      !Mixing ratio of ice
          fluxmelt(iq)  = fluxmelt(iq) + fluxice(iq)
          dttg          = -hlfcp*qif
          ttg(iq,k)     = ttg(iq,k) + dttg
          qsatg(iq,k)   = qsatg(iq,k) + gam1(iq)*dttg/hlscp
          cfmelt(iq)    = max( cfmelt(iq), cifra(iq) )
          fluxice(iq)   = 0.
          cifra(iq)     = 0.
          rdclfrice(iq) = 0.
          mxclfrice(iq) = 0.
        end if
      end do
      
      ! Compute the sublimation of ice falling from level k+1 into level k
      do iq = 1,imax
        qvp = rhov(iq,k)/rhoa(iq,k)
        if ( fluxice(iq)>0. .and. qvp<qsatg(iq,k) ) then ! sublime ice
          fsclr_i      = (1.-cifr(iq,k)-clfr(iq,k))*fluxice(iq)  
          Csb          = Csbsav(iq)*fluxice(iq)/tdt
          bf           = 1. + 0.5*Csb*tdt*(1.+gam1(iq))
          dqs          = max( 0., tdt*(Csb/bf)*(qsatg(iq,k)-qvp) )
          dqs          = min( dqs, (qsatg(iq,k)-qvp)/(1.+gam1(iq)) ) !Don't supersat.
          sublflux(iq) = min( dqs*rhodz(iq), fsclr_i ) ! flux of ice
          drf          = sublflux(iq)/dz(iq,k)                ! mass of ice
          dqs          = drf/rhoa(iq,k)                   ! mixing ratio of ice     
          fluxice(iq)  = fluxice(iq) - sublflux(iq)
          fsclr_i      = fsclr_i - sublflux(iq)
          rhov(iq,k)   = rhov(iq,k)  + drf
          qsubl(iq,k)  = qsubl(iq,k) + dqs
          dttg         = -hlscp*dqs
          ttg(iq,k)    = ttg(iq,k) + dttg
          qsatg(iq,k)  = qsatg(iq,k) + gam1(iq)*dttg/hlscp
        end if
      end do  
      
      ! Accretion of cloud liquid by falling ice (neglected in Lin et al 1983, but
      ! included in UM and ACCESS 1.3 as piacw)
      ! This calculation uses the incoming fluxice without subtracting sublimation
      ! (since subl occurs only outside cloud), so add sublflux back to fluxice.
      do iq = 1,imax
        rl = rhol(iq,k)
        if ( fluxice(iq)+sublflux(iq)>0. .and. rl>1.e-15 ) then
          slopes_i    = 1.6e3*10**(-0.023*(ttg(iq,k)-tfrz))
          cdt         = Eac*slopes_i*(fluxice(iq)+sublflux(iq))/(2.*rhosno)
          drl         = max( min( cifra(iq)*rl, rl*cdt/(1.+0.5*cdt) ), 0. ) ! mass of liquid
          lflux       = drl*dz(iq,k)   ! flux of liquid
          dql         = drl/rhoa(iq,k) ! mixing ratio of liquid
          fluxice(iq) = fluxice(iq) + lflux
          rhol(iq,k)  = rhol(iq,k)  - drl
          qaccr(iq,k) = qaccr(iq,k) + dql
          dttg        = hlfcp*dql
          ttg(iq,k)   = ttg(iq,k) + dttg
          qsatg(iq,k) = qsatg(iq,k) + gam1(iq)*dttg/hlscp
          cftmp       = clfr(iq,k)*drl/rl
          clfr(iq,k)  = clfr(iq,k) - cftmp
          mxclfrice(iq) = max( mxclfrice(iq), cftmp )
        end if
      end do
      
      if ( ncloud>=3 ) then
        ! Accretion of rain by falling ice to produce ice (from Lin et al 1983 - piacr)
        ! (see UM and ACCESS 1.3 piacr-c for an alternate formulation)
        do iq = 1,imax
          rn  = rhor(iq,k)
          if ( fluxice(iq)+sublflux(iq)>0. .and. rn>1.e-15 .and. ttg(iq,k)<tfrz ) then
            qf           = max(fluxice(iq)+sublflux(iq),0.)/rhodz(iq)  
            cdt          = tdt*denfac(iq)*c_piacr*qf/sqrt(rhoa(iq,k))
            drl          = max( min( cifra(iq)*rn, rn*cdt/(1.+0.5*cdt) ), 0. ) ! mass of rain
            lflux        = drl*dz(iq,k)   ! flux of rain
            dql          = drl/rhoa(iq,k) ! mixing ratio of rain
            fluxice(iq)  = fluxice(iq) + lflux
            rhor(iq,k)   = rhor(iq,k)  - drl
            dttg         = hlfcp*dql
            ttg(iq,k)    = ttg(iq,k) + dttg
            qsatg(iq,k)  = qsatg(iq,k) + gam1(iq)*dttg/hlscp
            cftmp        = cfrain(iq,k)*drl/rn
            cfrain(iq,k) = cfrain(iq,k) - cftmp
            mxclfrice(iq) = max( mxclfrice(iq), cftmp )
          end if
        end do
      end if 
      
      ! Accretion of rain by falling ice to produce graupel (Neglected in Lin et al 1983)
      ! (see UM and ACCESS 1.3 piacr-g for an alternate formulation)
      
    end if  

    ! store slope for aerosols
    do iq = 1,imax
      slopes_i      = 1.6e3*10**(-0.023*(ttg(iq,k)-tfrz))
      pslopes(iq,k) = pslopes(iq,k) + slopes_i*tdt/tdt_in  
    end do
    
    
    ! Rain --------------------------------------------------------------------------------
    evap(:) = 0.

    ! Add flux of melted snow to fluxrain
    fluxrain(:) = fluxrain(:) + fluxmelt(:) + fluxautorain(:,k)*tdt/tdt_in
    mxclfrrain(:) = max( mxclfrrain(:), cfmelt(:) )
    
    ! Detect maximum/random overlap clouds that are separated by a clear layer
    where ( (stratcloud(:,k)>=1.e-10.and.stratcloud(:,k+1)<1.e-10) .or. nmr==0 )
      rdclfrrain(:) = rdclfrrain + mxclfrrain - rdclfrrain*mxclfrrain
      mxclfrrain(:) = 0.
    end where
    crfra(:) = max( rdclfrrain + mxclfrrain - rdclfrrain*mxclfrrain, 1.e-15 )
    
    ! Calculate rain fall speed (MJT suggestion)
    if ( ncloud>=2 ) then
      do iq = 1,imax
        Fr(iq)       = max( fluxrain(iq)/tdt/max(crfra(iq),1.e-15),0.)
        vr2(iq)      = max( 0.1, 11.3*Fr(iq)**(1./9.)/sqrt(rhoa(iq,k)) )  !Actual fall speed
        !vr2iq)      = max( 0.1, 5./sqrt(rhoa(iq,k)) )                   !Nominal fall speed
        alph         = tdt*vr2(iq)/dz(iq,k)
        foutliq(iq)  = 1. - exp(-alph)
        fthruliq(iq) = 1. - foutliq(iq)/alph
      end do
    else
      foutliq(:)  = 1.
      fthruliq(:) = 1.
    end if
    
    if ( any( fluxrain>0. ) ) then

      alphaf(:) = hls*qsatg(:,k)/(rvap*ttg(:,k)**2)
      gam1(:)   = hlscp*alphaf !(L/cp)*dqsdt (HBG notation)
    
      if ( ncloud>=3 ) then
        ! Freezing rain to produce graupel (pgfr)
        ! (Neglected in UM and ACCESS 1.3)
        do iq = 1,imax
          rn = max(fluxrain(iq),0.)/dz(iq,k)
          if ( rn>1.e-15 .and. ttg(iq,k)<tfrz ) then
            slopes_r        = (( max(fluxrain(iq),0.)/max(crfra(iq),1.e-15)/tdt)**0.22)/714.
            ! MJT notes - limit temperature to -100 C to avoid overflow with single precision
            cdt             = tdt*20.e2*pi**2*n0r*(rho_r/rhoa(iq,k))*slopes_r**7 &
                                   *(exp(-0.66*max(ttg(iq,k)-tfrz,-100.))-1.)
            drl             = max( min( rn, rn*cdt/(1.+0.5*cdt) ), 0. )
            lflux           = min( drl*dz(iq,k), fluxrain(iq) ) ! flux
            lflux           = min( lflux, rhodz(iq)*(tfrz-ttg(iq,k))/hlfcp ) ! do not overshoot tfrz
            drl             = lflux/dz(iq,k) ! mass
            dql             = drl/rhoa(iq,k) ! mixing ratio
            fluxrain(iq)    = fluxrain(iq)    - lflux
            fluxgraupel(iq) = fluxgraupel(iq) + lflux
            fluxfreeze(iq)  = fluxfreeze(iq)  + lflux
            dttg            = hlfcp*dql
            ttg(iq,k)       = ttg(iq,k) + dttg
            qsatg(iq,k)     = qsatg(iq,k) + gam1(iq)*dttg/hlscp
            rdclfrrain(iq)  = rdclfrrain(iq)*(1.-drl/rn)
            mxclfrrain(iq)  = mxclfrrain(iq)*(1.-drl/rn)
            cltmp           = mxclfrrain(iq) + rdclfrrain(iq) - mxclfrrain(iq)*rdclfrrain(iq)
            mxclfrgraupel(iq) = max( mxclfrgraupel(iq), max(crfra(iq)-cltmp, 0.) )
            crfra(iq)       = cltmp
          end if
        end do

      end if     
      
      ! Evaporation of rain
      qpf(:)     = fluxrain/rhodz !Mix ratio of rain which falls into layer
      clrevap(:) = (1.-clfr(:,k)-cifr(:,k))*qpf
      where ( ttg(:,k)<tfrz .and. ttg(:,k)>=tice )
        qsl(:)   = qsatg(:,k) + epsil*esdiffx(ttg(:,k))/pk
      elsewhere
        qsl(:)   = qsatg(:,k)
      end where
      do iq = 1,imax
        qvp     = rhov(iq,k)/rhoa(iq,k)
        if ( fluxrain(iq)>0. .and. crfra(iq)>0. ) then
          es          = qsl(iq)*pk(iq)/epsil
          Apr         = (hl/(rKa*ttg(iq,k)))*(hl/(rvap*ttg(iq,k))-1.)
          Bpr         = rvap*ttg(iq,k)/((Dva/pk(iq))*es)
          Fr(iq)      = fluxrain(iq)/tdt/max(crfra(iq), 1.e-15)
          Cev         = crfra(iq)*3.8e2*sqrt(Fr(iq)/rhoa(iq,k))/(qsl(iq)*(Apr+Bpr))
          dqsdt       = hl*qsl(iq)/(rvap*ttg(iq,k)**2)
          bl          = 1. + 0.5*Cev*tdt*(1.+hlcp*dqsdt)
          evap(iq)    = tdt*(Cev/bl)*(qsl(iq)-qvp)
          satevap     = (qsl(iq)-qvp)/(1.+hlcp*dqsdt)  !Evap to saturate
          ! vr2=11.3*Fr(iq)**(1./9.)/sqrt(rhoa(mg,k)) !Actual fall speed
          ! vr2=5./sqrt(rhoa(mg,k))               !Nominal fall speed
          evap(iq) = max( 0., min( evap(iq), satevap, clrevap(iq) ) )
        end if
      end do
      select case(nevapls)
        case(-1)  
          evap(:) = 0.
        case(-2)
          where ( k<=ktsav(:) .and. condx(:)>0. )
            evap(:) = 0.
          end where
        case(-3)
          evap(:) = 0.5*evap
        case(-4)
          where ( k<=ktsav(:) .and. condx(:)>0. )
            evap(:) = 0.5*evap ! usual
          end where
      end select
      do iq = 1,imax
        drl        = evap(iq)*rhoa(iq,k) ! mass
        rhov(iq,k) = rhov(iq,k) + drl
        ttg(iq,k)  = ttg(iq,k) - hlcp*evap(iq)
        frclr(iq)  = rhodz(iq)*(clrevap(iq)-evap(iq)) ! flux over tdt
      end do  
      
      ! Now do the collection of liquid cloud by rain term (cf. pracc in Lin83).
      fcol(:) = 0.
      Fr(:) = 0.
      do iq = 1,imax
        rl = rhol(iq,k)
        if ( fluxrain(iq)>0. .and. rl>1.e-15 ) then
          Fr(iq)       = max(fluxrain(iq),0.)/tdt/max(crfra(iq),1.e-15)
          fcol(iq)     = crfra(iq)
          cdt          = tdt*Ecol*0.24*fcol(iq)*pow75(Fr(iq))
          coll         = max( min( rhol(iq,k), rhol(iq,k)*cdt/(1.+0.5*cdt) ), 0. ) ! mass
          lflux        = coll*dz(iq,k)                                            ! flux
          dql          = coll/rhoa(iq,k)                                          ! mixing ratio
          fluxrain(iq) = fluxrain(iq) + lflux
          rhol(iq,k)   = rhol(iq,k)   - coll
          qcoll(iq,k)  = qcoll(iq,k)  + dql
          cltmp        = clfr(iq,k)*coll/rl
          clfr(iq,k)   = clfr(iq,k) - cltmp
          mxclfrrain(iq) = max( mxclfrrain(iq), cltmp )
        end if
      end do
      
      ! subtract evaporated rain
      do iq = 1,imax
        lflux        = evap(iq)*rhodz(iq)
        fluxrain(iq) = max( fluxrain(iq) - lflux, 0. ) !To avoid roundoff -ve's
      end do
      
      if ( ncloud>=3 ) then
        ! Accretion of cloud snow by rain (from Lin et al 1983 - pracs)
        do iq = 1,imax
          rs = max( rhos(iq,k), 0. )
          if ( fluxrain(iq)>0. .and. rs>1.e-15 .and. ttg(iq,k)>tfrz+1. ) then
            n0s          = 2.e6*exp(-0.12*max(ttg(iq,k)-tfrz,-200.))        
            slopes_s     = ( max(rs,0.)/(pi*rho_s*n0s))**0.25
            slopes_r     = (( max(fluxrain(iq),0.)/max(crfra(iq),1.e-15)/tdt)**0.22)/714.  
            qsn          = max( rs/rhoa(iq,k), 0. )  
            cdt          = tdt*pi*pi*n0r*n0s*abs(vr2(iq)-vs2(iq))*qsn*(rho_s/rhoa(iq,k))        &
                                *(5.*slopes_s**6*slopes_r+2.*slopes_s**5*slopes_r**2  &
                                 +0.5*slopes_s**4*slopes_r**3)
            drf          = max( min( crfra(iq)*rs, rs*cdt/(1.+0.5*cdt) ), 0. ) ! mass
            lflux        = drf*dz(iq,k)                                     ! flux
            dqf          = drf/rhoa(iq,k)                                   ! mixing ratio
            fluxrain(iq) = fluxrain(iq) + lflux
            rhos(iq,k)   = rhos(iq,k)   - drf
            dttg         = hlfcp*dqf
            ttg(iq,k)    = ttg(iq,k) - dttg
            qsatg(iq,k)  = qsatg(iq,k) - gam1(iq)*dttg/hlscp      
            cftmp        = cfsnow(iq,k)*drf/rs
            cfsnow(iq,k) = cfsnow(iq,k) - cftmp
            mxclfrrain(iq) = max( mxclfrrain(iq), cftmp )
          end if
        end do

      end if   
      
      ! store for aerosols
      qevap(:,k) = qevap(:,k) + evap
      prscav(:,k) = prscav(:,k) + tdt*0.24*fcol*pow75(Fr)   !Strat only
      
    end if  
    
    
    ! Liquid ------------------------------------------------------------------------------
    ! (Currently cloud droplet settling is negected, although included in UM and ACCESS 1.3)


    ! Misc ------------------------------------------------------------------------------

    if ( any( fluxrain>0. ) ) then
    
      if ( ncloud>=3 ) then  
        ! Accretion of cloud ice by rain to produce snow or grauple (from Lin et al 1983 - praci)
        ! (Neglected in UM and ACCESS 1.3)
        do iq = 1,imax
          rf = rhoi(iq,k)
          rn = fluxrain(iq)/dz(iq,k)
          if ( rn>qr0_crt ) then
            xwgt = 1.
          else
            xwgt = 0.  
          end  if
          if ( fluxrain(iq)>0. .and. rf>1.e-15 .and. ttg(iq,k)<tfrz ) then
            slopes_r        = (( max(fluxrain(iq),0.)/max(crfra(iq),1.e-15)/tdt)**0.22)/714.  
            cdt             = tdt*pi*n0r*alin*gam380/4.*slopes_r**3.8*denfac(iq)
            drf             = max( min( crfra(iq)*rf, rf*cdt/(1.+0.5*cdt) ), 0. ) ! mass
            iflux           = drf*dz(iq,k)                                                                          ! flux
            rhoi(iq,k)      = rhoi(iq,k)      - drf
            fluxgraupel(iq) = fluxgraupel(iq) + iflux*xwgt
            fluxsnow(iq)    = fluxsnow(iq)    + iflux*(1.-xwgt)
            qaccf(iq,k)     = qaccf(iq,k)  + drf
            cftmp           = cifr(iq,k)*drf/rf
            cifr(iq,k)      = cifr(iq,k) - cftmp
            mxclfrgraupel(iq) = max( mxclfrgraupel(iq), cftmp*xwgt )
            mxclfrsnow(iq)    = max( mxclfrsnow(iq), cftmp*(1.-xwgt) )
          end if
        end do
        
      end if  
      
    end if  
  
    
    ! Update fluxes and area fractions for graupel, snow, ice and rain

    rhototf(:)       = rhog(:,k) + rhos(:,k) + rhoi(:,k)
    xfrac_graupel(:) = rhog(:,k)/max(rhototf(:),1.e-20)
    xfrac_snow(:)    = rhos(:,k)/max(rhototf(:),1.e-20)
    xfrac_ice(:)     = max( 0., 1.-xfrac_graupel(:)-xfrac_snow(:) )
    
    ! Melting and freezing
    fluxm(:,k) = fluxm(:,k) + fluxmelt(:)
    fluxf(:,k) = fluxf(:,k) + fluxfreeze(:)

    
    if ( ncloud>=3 ) then
        
      ! Grauple
      ! calculate maximum and random overlap for falling graupel
      pfstayice(:,k) = pfstayice(:,k) + fluxgraupel(:)*(1.-fthrugraupel(:))/tdt_in ! Save flux for the wet deposition scheme.  
      pqfsedice(:,k) = pqfsedice(:,k) + xfrac_graupel(:)*foutgraupel(:)*tdt/tdt_in ! Save sedimentation rate for aerosol scheme
      where ( fluxgraupel(:)<=0. )
        rdclfrgraupel(:) = 0.
        mxclfrgraupel(:) = 0.
      end where
      mxclfrgraupel(:) = max( mxclfrgraupel, cfgraupel(:,k) ) ! for rhogout
      cgfra(:) = max( 1.e-15, mxclfrgraupel+rdclfrgraupel-mxclfrgraupel*rdclfrgraupel ) ! rnd overlap
      ! Compute fluxes into the box
      cffluxin(:) = cgfra - cfgraupel(:,k)
      rhogin(:)   = fluxgraupel(:)/dz(:,k)
      ! Compute the fluxes of snow leaving the box
      cffluxout(:) = cfgraupel(:,k)*foutgraupel
      rhogout(:)   = rhog(:,k)*foutgraupel
      ! Update the rhos and cfsnow fields
      cfgraupel(:,k) = cfgraupel(:,k) - cffluxout(:) + cffluxin(:)*(1.-fthrugraupel)
      rhog(:,k)      = rhog(:,k) - rhogout + rhogin*(1.-fthrugraupel)
      fluxgraupel(:) = max( rhogout*dz(:,k) + fluxgraupel*fthrugraupel, 0. )
      where ( fluxgraupel<1.e-20 )
        rhog(:,k) = rhog(:,k) + fluxgraupel/dz(:,k)
        fluxgraupel = 0.
      end where  
      ! Now fluxgraupel is flux leaving layer k
      fluxg(:,k) = fluxg(:,k) + fluxgraupel
      
      ! Snow
      ! calculate maximum and random overlap for falling snow
      pfstayice(:,k) = pfstayice(:,k) + fluxsnow(:)*(1.-fthrusnow(:))/tdt_in ! Save flux for the wet deposition scheme.
      pqfsedice(:,k) = pqfsedice(:,k) + xfrac_snow(:)*foutsnow(:)*tdt/tdt_in ! Save sedimentation rate for aerosol scheme
      where ( fluxsnow(:)<=0. )
        rdclfrsnow(:) = 0.
        mxclfrsnow(:) = 0.
      end where
      mxclfrsnow(:) = max( mxclfrsnow, cfsnow(:,k) ) ! for rhosout
      csfra(:) = max( 1.e-15, mxclfrsnow+rdclfrsnow-mxclfrsnow*rdclfrsnow ) 
      ! Compute fluxes into the box
      cffluxin(:) = csfra - cfsnow(:,k)
      rhosin(:)   = fluxsnow(:)/dz(:,k)
      ! Compute the fluxes of snow leaving the box
      cffluxout(:) = cfsnow(:,k)*foutsnow
      rhosout(:)   = rhos(:,k)*foutsnow
      ! Update the rhos and cfsnow fields
      cfsnow(:,k) = cfsnow(:,k) - cffluxout + cffluxin*(1.-fthrusnow)
      rhos(:,k)   = rhos(:,k) - rhosout + rhosin*(1.-fthrusnow)
      fluxsnow(:) = max( rhosout*dz(:,k) + fluxsnow*fthrusnow, 0. )
      where ( fluxsnow<1.e-20 )
        rhos(:,k) = rhos(:,k) + fluxsnow/dz(:,k)
        fluxsnow = 0.
      end where  
      ! Now fluxsnow is flux leaving layer k
      fluxs(:,k) = fluxs(:,k) + fluxsnow
      
    end if ! ncloud>=3

    
    ! Ice
    ! calculate maximum and random overlap for falling ice
    pfstayice(:,k) = pfstayice(:,k) + fluxice(:)*(1.-fthruice(:))/tdt_in ! Save flux for the wet deposition scheme.
    pqfsedice(:,k) = pqfsedice(:,k) + xfrac_ice(:)*foutice(:)*tdt/tdt_in ! Save sedimentation rate for aerosol scheme
    where ( fluxice(:)<=0. )
      rdclfrice(:) = 0.
      mxclfrice(:) = 0.
    end where
    mxclfrice(:) = max( mxclfrice, cifr(:,k) ) ! for rhoiout
    cifra(:) = max( 1.e-15, mxclfrice+rdclfrice-mxclfrice*rdclfrice ) !rnd overlap the mx and rd ice fractions
    ! Compute fluxes into the box
    cffluxin(:) = cifra - cifr(:,k)
    rhoiin(:)   = fluxice/dz(:,k)
    ! Compute the fluxes of ice leaving the box
    cffluxout(:) = cifr(:,k)*foutice
    rhoiout(:)   = rhoi(:,k)*foutice
    ! Update the rhoi and cifr fields
    cifr(:,k)  = min( 1.-clfr(:,k), cifr(:,k)-cffluxout(:)+cffluxin*(1.-fthruice) )
    rhoi(:,k)  = rhoi(:,k) - rhoiout + rhoiin*(1.-fthruice)
    fluxice(:) = max( rhoiout*dz(:,k) + fluxice*fthruice, 0. )
    where ( fluxice<1.e-20 )
      rhoi(:,k) = rhoi(:,k) + fluxice/dz(:,k)
      fluxice = 0.
    end where  
    ! Now fluxice is flux leaving layer k
    fluxi(:,k) = fluxi(:,k) + fluxice  
  
    ! Rain
    ! Calculate the raining cloud cover down to this level, for stratiform (crfra).
    pfstayliq(:,k) = pfstayliq(:,k) + fluxrain(:)*(1.-fthruliq(:))/tdt_in ! store liquid flux for aerosols
    where ( fluxrain(:)<=0. )
      rdclfrrain(:) = 0.
      mxclfrrain(:) = 0.
    end where
    mxclfrrain(:) = max( mxclfrrain, cfrain(:,k) ) ! for rhorout    
    crfra(:) = max( 1.e-15, rdclfrrain+mxclfrrain-rdclfrrain*mxclfrrain )
    ! Compute fluxes into the box
    cffluxin(:) = crfra - cfrain(:,k)
    rhorin(:)   = fluxrain(:)/dz(:,k)
    ! Compute the fluxes of rain leaving the box
    ! Use the flux-divergent form as in Rotstayn (QJRMS, 1997)
    cffluxout(:) = cfrain(:,k)*foutliq
    rhorout(:)   = rhor(:,k)*foutliq
    ! Update the rhor and cfrain fields
    cfrain(:,k) = cfrain(:,k) - cffluxout + cffluxin*(1.-fthruliq)
    rhor(:,k)   = rhor(:,k) - rhorout + rhorin*(1.-fthruliq)
    fluxrain(:) = max( rhorout*dz(:,k) + fluxrain*fthruliq, 0. )
    where ( fluxrain<1.e-20 )
      rhor(:,k) = rhor(:,k) + fluxrain/dz(:,k)
      fluxrain = 0.
    end where
    ! Now fluxrain is flux leaving layer k
    fluxr(:,k) = fluxr(:,k) + fluxrain
    
  end do ! k
  
end do   ! n


! store precip, snow and graupel
precs(:) = precs + fluxr(:,1) + fluxi(:,1) + fluxs(:,1) + fluxg(:,1)
preci(:) = preci + fluxi(:,1) + fluxs(:,1)
precg(:) = precg + fluxg(:,1)

do k = 1,kl
  ! Re-create qtg, qrg, qlg, qfg, qsng and qgrg fields
  qtg(:,k)  = rhov(:,k)/rhoa(:,k)
  qrg(:,k)  = rhor(:,k)/rhoa(:,k)
  qfg(:,k)  = rhoi(:,k)/rhoa(:,k)
  qlg(:,k)  = rhol(:,k)/rhoa(:,k)
  qsng(:,k) = rhos(:,k)/rhoa(:,k)
  qgrg(:,k) = rhog(:,k)/rhoa(:,k)

  ! Remove small amounts of cloud and precip
  where ( qlg(:,k)<1.e-10 )
    qtg(:,k)  = qtg(:,k) + qlg(:,k)
    ttg(:,k)  = ttg(:,k) - hlcp*qlg(:,k)
    qlg(:,k)  = 0.
    clfr(:,k) = 0.
  end where
  where ( qfg(:,k)<1.e-10 )
    qtg(:,k)  = qtg(:,k) + qfg(:,k)
    ttg(:,k)  = ttg(:,k) - hlscp*qfg(:,k)
    qfg(:,k)  = 0.
    cifr(:,k) = 0.
  end where
  where ( qrg(:,k)<1.e-10 )
    qtg(:,k)    = qtg(:,k) + qrg(:,k)
    ttg(:,k)    = ttg(:,k) - hlcp*qrg(:,k)
    qrg(:,k)    = 0.
    cfrain(:,k) = 0.
  end where
  where ( qsng(:,k)<1.e-10 )
    qtg(:,k)    = qtg(:,k) + qsng(:,k)
    ttg(:,k)    = ttg(:,k) - hlscp*qsng(:,k)
    qsng(:,k)   = 0.
    cfsnow(:,k) = 0.
  end where
  where ( qgrg(:,k)<1.e-10 )
    qtg(:,k)       = qtg(:,k) + qgrg(:,k)
    ttg(:,k)       = ttg(:,k) - hlscp*qgrg(:,k)
    qgrg(:,k)      = 0.
    cfgraupel(:,k) = 0.
  end where
  qtg(:,k) = max( qtg(:,k), 0. )
    
  stratcloud(:,k) = clfr(:,k) + cifr(:,k)
  
end do  

#ifndef GPU
!      Adjust cloud fraction (and cloud cover) after precipitation
if ( nmaxpr==1 .and. mydiag ) then
  write(6,*) 'diags from newrain for idjd ',idjd
  diag_temp(:) = stratcloud(idjd,:)
  write (6,"('stratcloud',9f8.3/6x,9f8.3)") diag_temp
  diag_temp(:) = cfrain(idjd,:)
  write (6,"('cfrain    ',9f8.3/6x,9f8.3)") diag_temp
  diag_temp(:) = cfsnow(idjd,:)
  write (6,"('cfsnow    ',9f8.3/6x,9f8.3)") diag_temp
  diag_temp(:) = cfgraupel(idjd,:)
  write (6,"('cfgraupel ',9f8.3/6x,9f8.3)") diag_temp
end if

! Diagnostics for debugging
if ( diag .and. mydiag ) then
  diag_temp(:) = stratcloud(idjd,:)
  write(6,*) 'stratcloud',diag_temp
  diag_temp(:) = cifr(idjd,:)
  write(6,*) 'cifr',diag_temp
  diag_temp(:) = clfr(idjd,:)
  write(6,*) 'clfr',diag_temp
  diag_temp(:) = ttg(idjd,:)
  write(6,*) 'ttg',diag_temp
  diag_temp(:) = qsatg(idjd,:)
  write(6,*) 'qsatg',diag_temp         
  diag_temp(:) = qlg(idjd,:)
  write(6,*) 'qlg',diag_temp
  diag_temp(:) = qfg(idjd,:)
  write(6,*) 'qfg',diag_temp
  diag_temp(:) = qrg(idjd,:)
  write(6,*) 'qrg',diag_temp
  diag_temp(:) = qsng(idjd,:)
  write(6,*) 'qsng',diag_temp
  diag_temp(:) = qgrg(idjd,:)
  write(6,*) 'qgrg',diag_temp
  diag_temp(:) = qsubl(idjd,:)
  write(6,*) 'qsubl',diag_temp
  diag_temp(:) = rhoa(idjd,:)
  write(6,*) 'rhoa',diag_temp
  diag_temp(:) = rhos(idjd,:)
  write(6,*) 'rhos',diag_temp
  diag_temp(:) = fluxs(idjd,:)
  write(6,*) 'fluxs ',diag_temp
  !diag_temp(1:kl-1) = foutice(idjd,1:kl-1)
  !write(6,*) 'foutice',diag_temp(1:kl-1)
  !diag_temp(1:kl-1) = fthruice(idjd,1:kl-1)
  !write(6,*) 'fthruice',diag_temp(1:kl-1)
  diag_temp(:) = pqfsedice(idjd,:)
  write(6,*) 'pqfsedice',diag_temp
  diag_temp(:) = fluxm(idjd,:)
  write(6,*) 'fluxm',diag_temp
  write(6,*) 'cifra,fluxsnow',cifra(idjd),fluxsnow(idjd)
end if  ! (diag.and.mydiag)
#endif

return
end subroutine newsnowrain
    
subroutine progcloud(dt,qc,qtot,press,rho,fice,qs,t,rhcrit, &
                     dpsldt,nettend,stratcloud,imax,kl)
!$acc routine vector

use const_phys                    ! Physical constants
use parm_m, only : qgmin          ! Model configuration

implicit none

integer, intent(in) :: imax, kl
integer k
real, dimension(imax,kl), intent(inout) :: qc ! condensate = qf + ql
real, dimension(imax,kl), intent(in) :: qtot, rho, fice, qs, t, rhcrit, press
real, dimension(imax,kl), intent(in) :: dpsldt
real, dimension(imax,kl), intent(inout) :: nettend
real, dimension(imax,kl), intent(inout) :: stratcloud
real, dimension(imax) :: aa, bb, cc, at, a_dt, b_dt, cf1, cfeq, cfbar
real, dimension(imax) :: qv, omega, hlrvap, dqsdT, gamma, xf, dqs
real, intent(in) :: dt
real erosion_scale
real, parameter :: u00ramp = 0.01

! background erosion scale in 1/secs
erosion_scale = 1.E-6

!if ( ncloud>=5 ) then
!  ! convert convective mass flux from half levels to full levels
!  do k = 1,kl-1
!    cmflx(:,k) = rathb(k)*fluxtot(:,k)+ratha(k)*fluxtot(:,k+1)
!  end do
!  cmflx(:,kl) = rathb(kl)*fluxtot(:,kl)
!else ! ncloud==4
!  ! use convective area fraction in leoncld.f, instead of convective mass flux
!  cmflx = 0.
!end if

! calculate dqs = ((omega + grav*Mc)/(cp*rho)+nettend)*dqsdT*dt
!                 -------------------------------------------------------
!                 1 + (stratcloud + 0.5*da)*gamma
! MJT notes - GFDL AM adds (stratcloud+0.5*at*da)*gamma term

! Change in saturated volume fraction
! da = -0.5*(1.-cf)^2*dqs/(qs-qv)
! MJT notes - Tiedtke 93 does not use 0.5

! gamma = L/cp*dqsdT

! Follow GFDL AM approach since da=da(dqs), hence need to solve the above
! quadratic equation for dqs if da/=0

! dqs*dqs*AA + dqs*BB + CC = 0
! AA = 0.25*gamma*(1-cf)^2/(qs-qv)
! BB = -(1+gamma*cf)
! CC = ((omega + grav*mflx)/(cp*rho)+netten)*dqsdT*dt

do k = 1,kl
  stratcloud(:,k) = max( min( stratcloud(:,k), 1. ), 0. )  
    
  qv = qtot(:,k) - qc(:,k)  
  ! calculate vertical velocity, dqs/dT and gamma 
  omega = press(:,k)*dpsldt(:,k)
  hlrvap = (hl+fice(:,k)*hlf)/rvap
  dqsdT = qs(:,k)*hlrvap/(t(:,k)**2)
  gamma = (hlcp+fice(:,k)*hlfcp)*dqsdT
  
  xf = max(min( (qv/qs(:,k) - rhcrit(:,k) - u00ramp ) / ( 2.*u00ramp ), 1. ), 0. ) ! MJT suggestion
  
  !cc = ((omega + grav*cmflx(:,k))/(cp*rho(:,k))+nettend(:,k))*dt*dqsdT
  cc = (omega/(cp*rho(:,k))+nettend(:,k))*dt*dqsdT ! neglect cmflx
  at = 1.-stratcloud(:,k)
  aa = 0.5*at*at/max( qs(:,k)-qv, 1.e-20 )
  bb = 1.+gamma*stratcloud(:,k)
  where ( cc<=0. .and. xf>0. )
    !dqs = ( bb - sqrt( bb*bb - 2.*gamma*xf*aa*cc ) ) / ( gamma*xf*aa ) ! GFDL style
    !dqs = min( dqs, cc/(1. + 0.5*bb) )                                 ! GFDL style
    dqs = 2.*cc/( bb + sqrt( bb*bb - 2.*gamma*xf*aa*cc ) ) ! alternative form of quadratic equation
                                                           ! note that aa and bb have been multipled by 2 and -1, respectively.
    ! Large scale cloud formation via condensation (A)
    a_dt = -xf*aa*dqs
  elsewhere
    ! da = 0, so dqs can be solved from a linear equation
    dqs = cc/bb
    ! Large scale cloud formation via condensation (A)
    a_dt = 0.
  end where

  ! Large scale cloud destruction via erosion (B)
  b_dt = stratcloud(:,k)*erosion_scale*dt*max(qs(:,k)-qv, 1.e-20)/max(qc(:,k), 1.e-20)

  ! Integrate
  !   dcf/dt = (1-cf)*A - cf*B
  ! to give (use cf' = A-cf*(A+B))
  !   cf(t=1) = cfeq + (cf(t=0) - cfeq)*exp(-(A+B)*dt)
  !   cfeq = A/(A+B)
  ! Average cloud fraction over the interval t=tau to t=tau+1
  !   cfbar = cfeq - (cf(t=1) - cf(t=0))/((A+B)*dt)
  ! cfeq is the equilibrum cloud fraction that is approached with
  ! a time scale of 1/(A+B)
  where ( a_dt>1.e-20 .or. b_dt>1.e-20 )
    cfeq  = a_dt/(a_dt+b_dt)
    cf1   = cfeq + (stratcloud(:,k) - cfeq)*exp(-a_dt-b_dt)
    cfbar = cfeq + (stratcloud(:,k) - cf1 )/(a_dt+b_dt)
  elsewhere
    cfeq  = stratcloud(:,k)
    cf1   = stratcloud(:,k)
    cfbar = stratcloud(:,k)
  end where

  ! Change in condensate
  ! dqc = -dqs*(stratcloud+0.5*da) = -dqs*cfbar
  ! MJT notes - missing erosion term -cfbar*erosion_scale*dt*(qs-qv)
  qc(:,k) = max(min( qc(:,k) - max(cfbar,1.e-20)*dqs, qtot(:,k)-qgmin ), 0. )

  ! Change in cloud fraction
  where ( qc(:,k)>1.e-20 )
    stratcloud(:,k) = max(min( cf1, 1.), 1.e-20 )
  elsewhere
    ! MJT notes - cloud fraction is maintained (da=0.) while condesate evaporates (dqc<0.) until
    ! the condesate dissipates
    stratcloud(:,k) = 0.
    qc(:,k) = 0.
  end where

  ! Reset tendency and mass flux for next time-step
  nettend(:,k) = 0.
  
end do

return
end subroutine progcloud    
    
pure function pow75_s(x) result(ans)
!$acc routine vector
implicit none
real, intent(in) :: x
real ans, y
y=sqrt(x)
ans=y*sqrt(y)
end function pow75_s

pure function pow75_v(x) result(ans)
!$acc routine vector
implicit none
real, dimension(:), intent(in) :: x
real, dimension(size(x)) :: ans, y
y=sqrt(x)
ans=y*sqrt(y)
end function pow75_v    
    
end module leoncld_mod
