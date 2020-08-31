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
    
! These subroutines handle dynamics for the Mixed-Layer-Ocean model

! - Horizontal diffusion
! - Ocean dynamics
! - Ice dynamics

! This module links to mlo.f90 which solves for 1D physics of ocean
! and ice processes.  Currently the code assumes the hydrostatic
! approximation which is reasonably valid to 1km resolution.

! Ocean and sea-ice dynamics are based on the R-grid used by CCAM.
! z* coordinates are used by the ocean to improve density gradients.
! Flexible nudging options are used for error correction (see
! nesting.f90).
    
! Several versions of the pressure gradient terms are avaliable and
! are specified using mlojacobi.

module mlodynamics

implicit none

private
public mlodiffusion,mlohadv,mlodyninit
public gosig,gosigh,godsig,ocnsmag,ocneps,ocndelphi
public mlodiff,usetide,mlojacobi,mlomfix,nodrift
public dd
public nstagoffmlo,mstagf,koff

complex, save :: emsum
real, dimension(:,:), allocatable, save :: ee, eeu, eev
real, dimension(:), allocatable, save :: dd, ddu, ddv
real, dimension(:), allocatable, save :: bu, bv, cu, cv
real, dimension(:,:), allocatable, save :: gosig, gosigh, godsig
real, dimension(:,:), allocatable, save :: godsigu, godsigv, gosighu, gosighv
real, dimension(:,:), allocatable, save :: stwgt
integer, save      :: nstagoffmlo = 0       ! staggering offset
integer, save      :: usetide     = 1       ! tidal forcing (0=off, 1=on)
integer, parameter :: icemode     = 2       ! ice stress (0=free-drift, 1=incompressible, 2=cavitating)
integer, parameter :: mstagf      = 30      ! alternating staggering (0=off left, -1=off right, >0 alternating)
integer, parameter :: koff        = 1       ! time split stagger relative to A-grid (koff=0) or C-grid (koff=1)
integer, parameter :: nf          = 2       ! power for horizontal diffusion reduction factor
integer, parameter :: itnmax      = 6       ! number of interations for reversible staggering
integer, parameter :: nxtrrho     = 1       ! Estimate rho at t+1 (0=off, 1=on)
integer, save      :: mlodiff     = 0       ! diffusion (0=all, 1=scalars only)
integer, save      :: mlojacobi   = 1       ! density gradient method (0=off, 1=non-local spline, 6,7=AC2003)
integer, save      :: nodrift     = 0       ! Remove drift from eta (0=off, 1=on)
integer, save      :: mlomfix     = 1       ! Conserve T & S (0=off, 1=no free surface, 2=free surface)
real, parameter :: rhosn          = 330.    ! density snow (kg m^-3)
real, parameter :: rhoic          = 900.    ! density ice  (kg m^-3)
real, parameter :: grav           = 9.80616 ! gravitational constant (m s^-2)
real, save      :: ocndelphi      = 150.    ! horizontal diffusion reduction factor gradient (1.e6 = disabled)
real, save      :: ocnsmag        = 1.      ! horizontal diffusion (2. in Griffies (2000), 1.-1.4 in POM (Mellor 2004), 1. in SHOC)
real, save      :: ocneps         = 0.1     ! semi-implicit off-centring term
real, parameter :: maxicefrac     = 0.999   ! maximum ice fraction
real, parameter :: tol            = 5.E-4   ! Tolerance for SOR solver (water)
real, parameter :: itol           = 1.E1    ! Tolerance for SOR solver (ice)

contains

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! This subroutine initialises mlo dynamical arrays
!
subroutine mlodyninit

use cc_mpi
use indices_m
use map_m
use mlo, only : wlev,mloexpdep,mlosigma
use mlodynamicsarrays_m
use newmpar_m
use parm_m
use parmdyn_m
use soil_m

implicit none

integer ii, iq
real, dimension(ifull) :: odum
real, dimension(ifull,0:wlev) :: dephl
real, dimension(ifull,wlev) :: dep,dz
real, dimension(3*wlev) :: dumz,gdumz
logical, dimension(ifull+iextra,wlev) :: wtr
complex lsum

! calculate depths
allocate( dd(ifull+iextra) )
dd(:) = 0.
dep(:,:) = 0.
dz(:,:) = 0.
do ii = 1,wlev
  call mloexpdep(0,dep(:,ii),ii,0)
  call mloexpdep(1,dz(:,ii),ii,0)
end do
dephl(:,0) = 0.
dephl(:,1) = dz(:,1)
do ii = 2,wlev
  dephl(:,ii) = dephl(:,ii-1) + dz(:,ii)
end do
dd(1:ifull) = max(dephl(:,wlev), 1.E-8)
call bounds(dd,nrows=2)

! prep land-sea mask
allocate( ee(ifull+iextra,wlev) )
allocate( eeu(ifull+iextra,wlev), eev(ifull+iextra,wlev) )
ee  = 0.
eeu = 0.
eev = 0. 
do ii = 1,wlev
  where ( dz(:,ii)>1.e-4 .and. .not.land(1:ifull) )
    ee(1:ifull,ii) = 1.
  end where
end do  
call bounds(ee,nrows=2)
do ii = 1,wlev
  where ( ee(:,ii)>1.5 .or. ee(:,ii)<=0.5 )
    ee(:,ii) = 0.
  end where 
  eeu(1:ifull,ii) = ee(1:ifull,ii)*ee(ie,ii)
  eev(1:ifull,ii) = ee(1:ifull,ii)*ee(in,ii)
end do  
call boundsuv(eeu,eev,nrows=2)

wtr = abs(ee-1.)<1.e-20

! Calculate staggered depth arrays
allocate( ddu(ifull+iextra), ddv(ifull+iextra) )
ddu = 0.
ddv = 0.
ddu(1:ifull) = 0.5*(dd(1:ifull)+dd(ie))
ddv(1:ifull) = 0.5*(dd(1:ifull)+dd(in))
where ( abs(eeu(1:ifull,1))<1.e-20 )
  ddu(1:ifull) = 1.E-8
end where
where ( abs(eev(1:ifull,1))<1.e-20 )
  ddv(1:ifull) = 1.E-8
end where
call boundsuv(ddu,ddv)


! allocate memory for mlo dynamics arrays
call mlodynamicsarrays_init(ifull,iextra,wlev)

if ( abs(nmlo)>=3 .and. abs(nmlo)<=9 ) then
  ! Precompute weights for calculating staggered gradients
  allocate(stwgt(ifull,wlev))
  stwgt = 0.
  do ii = 1,wlev
    where ( wtr(in,ii) .and. wtr(ien,ii) .and. wtr(ie,ii) .and. wtr(ine,ii) .and. &
            wtr(is,ii) .and. wtr(ies,ii) .and. wtr(iw,ii) .and. wtr(inw,ii) .and. &
            wtr(1:ifull,ii) )
      stwgt(1:ifull,ii) = 1.
    end where
  end do      
end if ! abs(nmlo)>=3.and.abs(nmlo)<=9

! vertical levels (using sigma notation)
allocate(gosig(1:ifull+iextra,wlev),gosigh(1:ifull,wlev),godsig(1:ifull+iextra,wlev))
allocate(godsigu(1:ifull+iextra,wlev),godsigv(1:ifull+iextra,wlev))
allocate(gosighu(1:ifull,wlev),gosighv(1:ifull,wlev))
gosig = 0.
gosigh = 0.
godsig = 0.
godsigu = 0.
godsigv = 0.
do ii = 1,wlev
  gosig(1:ifull,ii)  = max(dep(1:ifull,ii),1.e-8)/dd(1:ifull)
  gosigh(1:ifull,ii) = max(dephl(1:ifull,ii),1.e-8)/dd(1:ifull)
  godsig(1:ifull,ii) = dz(1:ifull,ii)/dd(1:ifull)*ee(1:ifull,ii)
end do
if ( mlosigma>=0 .and. mlosigma<=3 ) then
  ! sigma levels  
  dumz = 0.
  do iq = 1,ifull
    if (.not.land(iq)) then
      do ii = 1,wlev
        dumz(ii)       =max(dumz(ii),gosig(iq,ii))
        dumz(ii+wlev)  =max(dumz(ii+wlev),gosigh(iq,ii))
        dumz(ii+2*wlev)=max(dumz(ii+2*wlev),godsig(iq,ii))
      end do
    end if 
  end do
  call ccmpi_allreduce(dumz(1:3*wlev),gdumz(1:3*wlev),"max",comm_world)
  do ii = 1,wlev
    gosig(:,ii)  = gdumz(ii)
    gosigh(:,ii) = gdumz(ii+wlev)
    godsig(:,ii) = gdumz(ii+2*wlev)
  end do    
else
  ! z* levels
  call bounds(gosig,nrows=2)
  call bounds(godsig,nrows=2)
end if
do ii = 1,wlev
  godsigu(1:ifull,ii) = 0.5*(godsig(1:ifull,ii)+godsig(ie,ii))*eeu(1:ifull,ii)
  godsigv(1:ifull,ii) = 0.5*(godsig(1:ifull,ii)+godsig(in,ii))*eev(1:ifull,ii)
end do  
call boundsuv(godsigu,godsigv)
gosighu(:,1) = godsigu(1:ifull,1)
gosighv(:,1) = godsigv(1:ifull,1)
do ii = 2,wlev
  gosighu(:,ii) = gosighu(:,ii-1) + godsigu(1:ifull,ii)
  gosighv(:,ii) = gosighv(:,ii-1) + godsigv(1:ifull,ii)
end do
do ii = 1,wlev
  gosighu(:,ii) = max(gosighu(:,ii),1.e-8/ddu)
  gosighv(:,ii) = max(gosighv(:,ii),1.e-8/ddv)
end do

! store correction for nodrift==1
odum = ee(1:ifull,1)*em(1:ifull)**2
call mlosum(odum,lsum)
call ccmpi_allreduce(lsum,emsum,"sumdr",comm_world)

allocate( bu(1:ifull), bv(1:ifull), cu(1:ifull), cv(1:ifull) )

return
end subroutine mlodyninit

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! This subroutine processes horizontal diffusion, based on Griffies (2000)
! and McGregor's hordifg.f routines for CCAM.
subroutine mlodiffusion

use mlo
use newmpar_m

implicit none

real, dimension(ifull,wlev) :: u,v,tt,ss

! extract data from MLO
u=0.
v=0.
tt=0.
ss=0.
call mloexport3d(0,tt,0)
call mloexport3d(1,ss,0)
call mloexport3d(2,u,0)
call mloexport3d(3,v,0)

call mlodiffusion_work(u,v,tt,ss)

call mloimport3d(0,tt,0)
call mloimport3d(1,ss,0)
call mloimport3d(2,u,0)
call mloimport3d(3,v,0)

return
end subroutine mlodiffusion

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! This subroutine implements some basic hydrostatic dynamics for the
! ocean and ice.  The ocean component employs the R-grid design used
! in CCAM semi-Lagragain dynamics, but uses sigma-z vertical
! coordinates.  The staggered/unstaggered pivoting has been modified
! for the land-sea boundary.  Sea-ice is advected using an upwind
! scheme.  Internal sea-ice pressure follows a cavitating fluid
! apporximation.
subroutine mlohadv

use arrays_m
use cc_mpi
use const_phys
use infile
use indices_m
use latlong_m
use map_m
use mlo
use mlodynamicsarrays_m
use newmpar_m
use nharrs_m, only : lrestart
use parm_m
use parmdyn_m
use soil_m
use soilsnow_m
use vecsuv_m

implicit none

integer ii,totits
integer jyear,jmonth,jday,jhour,jmin,mins
integer tyear,jstart, iq, mspec_mlo, mspeca_mlo
integer, dimension(ifull,wlev) :: nface
real maxglobseta,maxglobip,hdt,dtin_mlo
real alph_p, delta
real, save :: dtsave=0.
real, dimension(2) :: delpos, delneg
real, dimension(ifull+iextra) :: neta,pice,imass
real, dimension(ifull+iextra) :: nfracice,ndic,ndsn,nsto,niu,niv
real, dimension(ifull+iextra) :: sou,sov,snu,snv
real, dimension(ifull+iextra) :: tide, depdum_rho
real, dimension(ifull+iextra) :: ipmax, spnet
real, dimension(ifull+iextra) :: bb, bb3u, bb4v
real, dimension(ifull+iextra) :: ibb, ibb3u, ibb4v
real, dimension(ifull) :: lbu, lbv, lcu, lcv
real, dimension(ifull) :: cc_n, cc_s, cc_e, cc_w
real, dimension(ifull) :: dzdxu, dzdxv, dzdyu, dzdyv
real, dimension(ifull) :: ibb_n, ibb_s, ibb_e, ibb_w
real, dimension(ifull) :: bb_n, bb_e
real, dimension(ifull) :: i_u,i_v,i_sto
real, dimension(ifull) :: w_e,xps,oeu,oev
real, dimension(ifull) :: tnu,tsu,tev,twv
real, dimension(ifull) :: dpsdxu,dpsdyu,dpsdxv,dpsdyv
real, dimension(ifull) :: dttdxu,dttdyu,dttdxv,dttdyv
real, dimension(ifull) :: detadxu,detadyu,detadxv,detadyv
real, dimension(ifull) :: dipdxu,dipdyu,dipdxv,dipdyv
real, dimension(ifull) :: odum,ibu,ibv
real, dimension(ifull) :: dd_e, dd_n, dd_w, dd_s
real, dimension(ifull) :: pice_n, pice_e, pice_s, pice_w
real, dimension(ifull) :: tide_n, tide_s, tide_e, tide_w
real, dimension(ifull) :: f_n, f_e, f_s, f_w
real, dimension(ifull) :: neta_n, neta_s, neta_e, neta_w
real, dimension(ifull) :: ipice_n, ipice_s, ipice_e, ipice_w
real, dimension(ifull) :: dd_isv, dd_iwu, em_isv, em_iwu, ee_isv, ee_iwu
real, dimension(ifull) :: oev_isv, oeu_iwu, cc_isv, cc_iwu
real, dimension(ifull) :: eo_isv, eo_iwu, ni_isv, ni_iwu
real, dimension(ifull) :: dnetadx, dnetady, ddddx, ddddy
real, dimension(ifull) :: sdiv
real, dimension(ifull) :: gosigu, gosigv, gosig_n, gosig_e
real, dimension(ifull+iextra,wlev,3) :: cou
real, dimension(ifull+iextra,wlev+1) :: cc
real, dimension(ifull+iextra,wlev) :: eou,eov,ccu,ccv
real, dimension(ifull+iextra,wlev) :: nu,nv,nt,ns
real, dimension(ifull+iextra,9) :: data_c,data_d
real, dimension(ifull+iextra,4) :: nit
real, dimension(ifull,wlev+1) :: tau,tav,ttau,ttav
real, dimension(ifull,wlev) :: w_u,w_v,w_t,w_s
real, dimension(ifull,wlev) :: nuh,nvh,xg,yg,uau,uav
real, dimension(ifull,wlev) :: kku,kkv,oou,oov
real, dimension(ifull,wlev) :: drhobardxu,drhobardyu,drhobardxv,drhobardyv
real, dimension(ifull,wlev) :: rhobaru, rhobarv, rhobar
real, dimension(ifull,wlev) :: depdum,dzdum,mfixdum
real, dimension(ifull,wlev) :: mps, workdata, worku, workv
real, dimension(ifull,0:wlev) :: nw
real, dimension(ifull,4) :: i_it
real, dimension(ifull,3) :: gamm
real(kind=8), dimension(ifull,wlev) :: x3d,y3d,z3d
logical lleap
logical, dimension(ifull+iextra,wlev) :: wtr
complex lsum, gsum

! Vertical coordinates are defined as:
!  mlosigma=0,1,2,3
!   sig = (z+eta)/(D+eta)
!  mlosigma=4,5,6,7
!   z* = D*(z+eta)/(D+eta) = sig*D
!   from Adcroft and Campin 2003 (see also MPAS)

! Instead of packing ocean points, we keep the original
! grid and define a land/sea mask.  This allows us to
! use the same index and map factor arrays from the
! atmospheric dynamical core.

! save time-step
dtin_mlo = dt
mspeca_mlo = 1

! Define land/sea mask
wtr(:,:) = ee(:,:)>0.5

! Default values
w_t      = 293.16-wrtemp ! potential water temperature delta at tau=t
w_s      = 34.72         ! water salinity at tau=t
w_u      = 0.            ! u component of water current at tau=t
w_v      = 0.            ! v component of water current at tau=t
w_e      = 0.            ! free surface height at tau=t
i_it     = 273.16        ! ice temperature
i_sto    = 0.            ! ice brine storage
i_u      = 0.            ! u component of ice velocity
i_v      = 0.            ! v component of ice velocity
nw       = 0.            ! water vertical velocity
pice     = 0.            ! ice pressure for cavitating fluid
imass    = 0.            ! ice mass
tide     = 0.            ! tidal forcing
nt       = 0.            ! new water temperature
ns       = 0.            ! new water salinity
nu       = 0.            ! new u component of water current
nv       = 0.            ! new v component of water current
neta     = 0.            ! new free surface height
niu      = 0.            ! new u component of ice velocity
niv      = 0.            ! new v component of ice velocity
nfracice = 0.            ! new ice fraction
ndic     = 0.            ! new ice thickness 
ndsn     = 0.            ! new ice snow depth 
cou      = 0.            ! working array
data_c   = 0.            ! working array
data_d   = 0.            ! working array
eou      = 0.            ! working array
eov      = 0.            ! working array
cc       = 0.

! EXPORT WATER AND ICE DATA FROM MLO ------------------------------------------
call mloexport3d(0,w_t,0)
call mloexport3d(1,w_s,0)
call mloexport3d(2,w_u,0)
call mloexport3d(3,w_v,0)
call mloexport(4,w_e,0,0)
do ii = 1,4
  call mloexpice(i_it(:,ii),ii,0)
end do
call mloexpice(nfracice,5,0)
call mloexpice(ndic,6,0)
call mloexpice(ndsn,7,0)
call mloexpice(i_sto,8,0)
call mloexpice(i_u,9,0)
call mloexpice(i_v,10,0)
where ( wtr(1:ifull,1) )
  fracice(1:ifull) = nfracice(1:ifull)  
  sicedep(1:ifull) = ndic(1:ifull)
  snowd(1:ifull)   = ndsn(1:ifull)*1000.
end where  

! estimate tidal forcing (assumes leap days)
if ( usetide==1 ) then
  call getzinp(jyear,jmonth,jday,jhour,jmin,mins,allleap=.true.)
  jstart = 0
  if ( jyear>1900 ) then
    do tyear = 1900,jyear-1
      call mloleap(tyear,lleap)
      if ( lleap ) jstart = jstart + 1
      jstart = jstart + 365
    end do
  else if ( jyear<1900 ) then
    do tyear = 1899,jyear,-1
      call mloleap(tyear,lleap)
      if ( lleap ) jstart = jstart - 1
      jstart = jstart - 365
    end do
  end if
  mins = mins + 720 ! base time is 12Z 31 Dec 1899
  call mlotide(tide,rlongg,rlatt,mins,jstart)
end if

! initialise t+1 variables with t data
neta(1:ifull)=w_e
nu(1:ifull,:)=w_u
nv(1:ifull,:)=w_v
nt(1:ifull,:)=w_t
ns(1:ifull,:)=w_s
nit(1:ifull,:)=i_it
nsto(1:ifull)=i_sto
niu(1:ifull)=i_u
niv(1:ifull)=i_v

! initialise save arrays
if ( ktau==1 .and. .not.lrestart ) then
  oldu1 = nu(1:ifull,:)
  oldv1 = nv(1:ifull,:)
  oldu2 = nu(1:ifull,:)
  oldv2 = nv(1:ifull,:)
  ipice = 0. ! ice free drift solution
  mspeca_mlo = 2
  dt = 0.5*dtin_mlo
end if


workdata = nt(1:ifull,:)
worku = nu(1:ifull,:)
workv = nv(1:ifull,:)
call mlocheck("start of mlodynamics",water_temp=workdata,water_u=worku,water_v=workv, &
                  ice_tsurf=nit(1:ifull,1))


do mspec_mlo = mspeca_mlo,1,-1

  hdt = 0.5*dt
    
  if ( mspeca_mlo==2 .and. mspec_mlo==1 ) then
    nu(1:ifull,:) = oldu1
    nv(1:ifull,:) = oldv1
    w_t = nt(1:ifull,:)
    w_s = ns(1:ifull,:)
    w_e = neta(1:ifull)
  end if
  
  ! surface pressure and ice mass
  ! (assume ice velocity is 'slow' compared to 'fast' change in neta)
  imass(1:ifull) = ndic(1:ifull)*rhoic + ndsn(1:ifull)*rhosn  ! ice mass per unit area (kg/m^2), unstaggered at time t
  pice(1:ifull) = ps(1:ifull)                                 ! pressure due to atmosphere at top of water column (unstaggered at t)
  if ( usepice==1 ) then
    pice(1:ifull) = pice(1:ifull) + grav*nfracice(1:ifull)*imass(1:ifull) ! include ice in surface pressure
  end if
  ! Limit minimum ice mass for ice velocity calculation.  Hence, we can solve for the ice velocity at
  ! grid points where the ice is not yet present.  
  imass(1:ifull) = max( imass(1:ifull), minicemass )
  ! maximum pressure for ice
  select case(icemode)
    case(2)
      ! cavitating fluid
      ipmax(1:ifull) = 27500.*ndic(1:ifull)*exp(-20.*(1.-nfracice(1:ifull)))*ee(1:ifull,1)
    case(1)
      ! incompressible fluid
      ipmax(1:ifull) = 9.E9*ee(1:ifull,1)
    case DEFAULT
      ! free drift
      ipmax(1:ifull) = 0.
  end select

  ! update scalar bounds and various gradients (aggregate fields for MPI)
  data_c(1:ifull,1) = neta(1:ifull)
  data_c(1:ifull,2) = pice(1:ifull)
  data_c(1:ifull,3) = tide(1:ifull)
  data_c(1:ifull,4) = imass(1:ifull)
  data_c(1:ifull,5) = ipmax(1:ifull)
  call bounds(data_c(:,1:5),corner=.true.)
  neta(ifull+1:ifull+iextra)  = data_c(ifull+1:ifull+iextra,1)
  pice(ifull+1:ifull+iextra)  = data_c(ifull+1:ifull+iextra,2)
  tide(ifull+1:ifull+iextra)  = data_c(ifull+1:ifull+iextra,3)
  imass(ifull+1:ifull+iextra) = data_c(ifull+1:ifull+iextra,4)
  ipmax(ifull+1:ifull+iextra) = data_c(ifull+1:ifull+iextra,5)

  call unpack_nsew(f,f_n,f_s,f_e,f_w)
  call unpack_nsew(neta,neta_n,neta_s,neta_e,neta_w)
  call unpack_nsew(dd,dd_n,dd_s,dd_e,dd_w)
  call unpack_svwu(ddu,ddv,dd_isv,dd_iwu)
  call unpack_svwu(emu,emv,em_isv,em_iwu)
  call unpack_svwu(eeu(:,1),eev(:,1),ee_isv,ee_iwu)

  ! surface pressure
  call unpack_nsew(pice,pice_n,pice_s,pice_e,pice_w)
  do iq = 1,ifull
    tnu(iq) = 0.5*( pice_n(iq) + pice(ien(iq)) )
    tsu(iq) = 0.5*( pice_s(iq) + pice(ies(iq)) )
    tev(iq) = 0.5*( pice_e(iq) + pice(ine(iq)) )
    twv(iq) = 0.5*( pice_w(iq) + pice(inw(iq)) )
  end do  
  dpsdxu = (pice_e-pice(1:ifull))*emu(1:ifull)/ds ! staggered at time t
  dpsdyu = 0.5*stwgt(1:ifull,1)*(tnu-tsu)*emu(1:ifull)/ds
  dpsdxv = 0.5*stwgt(1:ifull,1)*(tev-twv)*emv(1:ifull)/ds
  dpsdyv = (pice_n-pice(1:ifull))*emv(1:ifull)/ds
 
  ! tides
  call unpack_nsew(tide,tide_n,tide_s,tide_e,tide_w)
  do iq = 1,ifull
    tnu(iq) = 0.5*( tide_n(iq) + tide(ien(iq)) )
    tsu(iq) = 0.5*( tide_s(iq) + tide(ies(iq)) )
    tev(iq) = 0.5*( tide_e(iq) + tide(ine(iq)) )
    twv(iq) = 0.5*( tide_w(iq) + tide(inw(iq)) )
  end do  
  dttdxu = (tide_e-tide(1:ifull))*emu(1:ifull)/ds ! staggered
  dttdyu = 0.5*stwgt(1:ifull,1)*(tnu-tsu)*emu(1:ifull)/ds
  dttdxv = 0.5*stwgt(1:ifull,1)*(tev-twv)*emv(1:ifull)/ds
  dttdyv = (tide_n-tide(1:ifull))*emv(1:ifull)/ds

  ! for 5-point stencil
  if ( abs(dt-dtsave)>1.e-20 ) then
    bb(1:ifull) = -ee(1:ifull,1)*(1.+ocneps)*0.5*dt/(1.+((1.+ocneps)*0.5*dt*f(1:ifull))**2) ! unstaggered
    call bounds(bb,nehalf=.true.)
    call unpack_ne(bb,bb_n,bb_e)
    bu = 0.5*(bb(1:ifull)+bb_e)*eeu(1:ifull,1)
    bv = 0.5*(bb(1:ifull)+bb_n)*eev(1:ifull,1)
    cu =  bu*(1.+ocneps)*0.5*dt*fu
    cv = -bv*(1.+ocneps)*0.5*dt*fv
    dtsave = dt
  end if
  
  
  call START_LOG(watereos_begin)

  ! Calculate adjusted depths and thicknesses
  do ii = 1,wlev
    depdum(1:ifull,ii) = gosig(1:ifull,ii)*max( dd(1:ifull)+neta(1:ifull), minwater )
    dzdum(1:ifull,ii)  = godsig(1:ifull,ii)*max( dd(1:ifull)+neta(1:ifull), minwater )
  end do  
  
  ! Calculate normalised density coeffs dalpha and dbeta (unstaggered at time t)
  ! (Assume free surface correction is small so that changes in the compression 
  ! effect due to neta can be neglected.  Consequently, the neta dependence is 
  ! separable in the iterative loop)
  call bounds(nt,corner=.true.)
  call bounds(ns,corner=.true.)

  ! Calculate normalised density gradients
  ! method 2: Use potential temperature and salinity Jacobians (see Shchepetkin and McWilliams 2003)
  call tsjacobi(nt,ns,pice,drhobardxu,drhobardyu,drhobardxv,drhobardyv,rhobar,rhobaru,rhobarv)

  call END_LOG(watereos_end)


  ! ADVECT WATER AND ICE ----------------------------------------------
  ! Water currents are advected using semi-Lagrangian advection
  ! based on McGregor's CCAM advection routines.
  ! Velocity is set to zero at ocean boundaries.
  
  ! Estimate currents at t+1/2 for semi-Lagrangian advection
  do ii = 1,wlev
    nuh(:,ii) = (15.*nu(1:ifull,ii)-10.*oldu1(:,ii)+3.*oldu2(:,ii))*ee(1:ifull,ii)/8. ! U at t+1/2
    nvh(:,ii) = (15.*nv(1:ifull,ii)-10.*oldv1(:,ii)+3.*oldv2(:,ii))*ee(1:ifull,ii)/8. ! V at t+1/2
  end do
  nuh = min( max( nuh, -50. ), 50. )
  nvh = min( max( nvh, -50. ), 50. )

  ! save arrays for extrapolating currents at next time-step
  oldu2(1:ifull,1:wlev) = oldu1(1:ifull,1:wlev)
  oldv2(1:ifull,1:wlev) = oldv1(1:ifull,1:wlev)
  oldu1(1:ifull,1:wlev) = nu(1:ifull,1:wlev)
  oldv1(1:ifull,1:wlev) = nv(1:ifull,1:wlev)


  ! Define horizontal transport
  ! dH(phi)/dt = d(phi)/dt + u*d(phi)/dx + v*d(phi)/dy
  
  ! Continuity equation
  ! 1/(neta+D) dH(neta+D)/dt + du/dx + dv/dy + dw/dz = 0
  ! dH(neta+D)/dt + (neta+D)*(du/dx+dv/dy) + (neta+D)*dw/dz = 0
  ! dH(neta)/dt + neta*(du/dx+dv/dy) + d(D*u)/dx + d(D*v)/dy + dw/dsig = 0  ! where D is now included in flux form
  
  ! Lagrangian version of the contunity equation with D included in flux form
  !   [neta + (1+eps)*0.5*dt*(neta*(du/dx+dv/dy)+d(D*u)/dx+d(D*v)/dy+dw/dsig)]^(t+1)
  ! = [neta - (1-eps)*0.5*dt*(neta*(du/dx+dv/dy)+d(D*u)/dx+d(D*v)/dy+dw/dsig)]^(t*)
  
  ! Vertical velocity is then (sum_0_sig is the integral from 0 to sig)

  ! w = -(neta+D)*sum_0_sig(du/dx+dv/dy,dsig) + (neta+D)*sig*sum_0_1(du/dx+dv/dy,dsig)
  !     -sum_0_sig(u*d(neta+D)/dx+v*d(neta+D)/dy),dsig) + sum_0_1(u*d(neta+D)/dx+v*d(neta+D)/dy,dsig)
  !   = -sum_0_sig(d(u*(neta+D))/dx+d(v*(neta+D))/dy,dsig) + sig*sum_0_1(d(u*(neta+D))/dx+d(v*(neta+D))/dy,dsig)

  ! Advect continuity equation to tstar
  ! Calculate velocity on C-grid for consistancy with iterative free surface calculation
  ! nw is at half levels with nw(:,1) at the bottom of level 1
  ! positive nw is moving downwards to the ocean floor
  ! Assume Boussinesq fluid and treat density in continuity equation as constant
  ! true vertical velocity = nw-u*((1-sig)*deta/dx-sig*d(dd)/dx)-v*((1-sig)*deta/dy-sig*d(dd)/dy)-(1-sig)*deta/dt
  call mlostaguv(nu(:,1:wlev),nv(:,1:wlev),eou(:,1:wlev),eov(:,1:wlev))
  call boundsuv(eou(:,1:wlev),eov(:,1:wlev),stag=-9)
  ! vertically integrate currents
  ccu(:,1) = eou(:,1)*godsigu(:,1)
  ccv(:,1) = eov(:,1)*godsigv(:,1)
  do ii = 2,wlev
    ccu(:,ii) = ccu(:,ii-1) + eou(:,ii)*godsigu(:,ii)
    ccv(:,ii) = ccv(:,ii-1) + eov(:,ii)*godsigv(:,ii)
  end do
  ! surface height at staggered coordinate
  oeu(1:ifull) = 0.5*(neta_e+neta(1:ifull))*eeu(1:ifull,1)
  oev(1:ifull) = 0.5*(neta_n+neta(1:ifull))*eev(1:ifull,1)
  oeu_iwu = 0.5*(neta_w+neta(1:ifull))*ee_iwu
  oev_isv = 0.5*(neta_s+neta(1:ifull))*ee_isv
  ! calculate vertical velocity (use flux form)
  call unpack_svwu(ccu(:,wlev),ccv(:,wlev),cc_isv,cc_iwu)
  sdiv(:) = (ccu(1:ifull,wlev)*(ddu(1:ifull)+oeu(1:ifull))/emu(1:ifull)    &
            -cc_iwu*(dd_iwu+oeu_iwu)/em_iwu                                &
            +ccv(1:ifull,wlev)*(ddv(1:ifull)+oev(1:ifull))/emv(1:ifull)    &
            -cc_isv*(dd_isv+oev_isv)/em_isv)*em(1:ifull)**2/ds
  do ii = 1,wlev-1
    call unpack_svwu(ccu(:,ii),ccv(:,ii),cc_isv,cc_iwu)  
    nw(:,ii) = ee(1:ifull,ii)*ee(1:ifull,ii+1)*(sdiv(:)*gosigh(1:ifull,ii) &
               - (ccu(1:ifull,ii)*(ddu(1:ifull)+oeu(1:ifull))/emu(1:ifull) &
                 -cc_iwu*(dd_iwu+oeu_iwu)/em_iwu                           &
                 +ccv(1:ifull,ii)*(ddv(1:ifull)+oev(1:ifull))/emv(1:ifull) &
                 -cc_isv*(dd_isv+oev_isv)/em_isv)*em(1:ifull)**2/ds)
  end do

  ! compute contunity equation horizontal transport terms
  mps = 0.
  do ii = 1,wlev
    call unpack_svwu(eou(:,ii),eov(:,ii),eo_isv,eo_iwu)  
    where ( wtr(1:ifull,ii) )
      mps(1:ifull,ii) = neta(1:ifull) - (1.-ocneps)*0.5*dt                          &
                       *((eou(1:ifull,ii)*(ddu(1:ifull)+neta(1:ifull))/emu(1:ifull) &
                         -eo_iwu*(dd_iwu+neta(1:ifull))/em_iwu                      &
                         +eov(1:ifull,ii)*(ddv(1:ifull)+neta(1:ifull))/emv(1:ifull) &
                         -eo_isv*(dd_isv+neta(1:ifull))/em_isv)                     &
                         *em(1:ifull)**2/ds                                         &
                        +(nw(:,ii)-nw(:,ii-1))/godsig(1:ifull,ii))
    end where  
  end do
      
  
  ! calculate vertical velocity at full levels for diagnostic output
  dnetadx = (oeu(1:ifull)/emu(1:ifull)-oeu_iwu/em_iwu)*em(1:ifull)**2/ds
  dnetady = (oev(1:ifull)/emv(1:ifull)-oev_isv/em_isv)*em(1:ifull)**2/ds
  ddddx = (ddu(1:ifull)/emu(1:ifull)-dd_iwu/em_iwu)*em(1:ifull)**2/ds
  ddddy = (ddv(1:ifull)/emv(1:ifull)-dd_isv/em_isv)*em(1:ifull)**2/ds
  do ii = 1,wlev  
    w_ocn(:,ii) = ee(1:ifull,ii)*(0.5*(nw(:,ii-1)+nw(:,ii))                                   &
                - nu(1:ifull,ii)*((1.-gosig(1:ifull,ii))*dnetadx - gosig(1:ifull,ii)*ddddx)   &
                - nv(1:ifull,ii)*((1.-gosig(1:ifull,ii))*dnetady - gosig(1:ifull,ii)*ddddy))
               !- (1.-gosig(1:ifull,ii))*dnetadt ! neglect for now 
  end do

  
  ! ocean
  ! Prepare pressure gradient terms at time t and incorporate into velocity field
  detadxu = (neta_e-neta(1:ifull))*emu(1:ifull)/ds
  detadyv = (neta_n-neta(1:ifull))*emv(1:ifull)/ds
  oeu(1:ifull) = 0.5*(neta_e+neta(1:ifull))*eeu(1:ifull,1)
  oev(1:ifull) = 0.5*(neta_n+neta(1:ifull))*eev(1:ifull,1)
  do ii = 1,wlev
    call unpack_ne(gosig(:,ii),gosig_n,gosig_e)    
    gosigu = 0.5*(gosig(1:ifull,ii)+gosig_e)
    gosigv = 0.5*(gosig(1:ifull,ii)+gosig_n)
    tau(:,ii) = grav*gosigu*ddu(1:ifull)*drhobardxu(:,ii)/wrtrho  &
               + dpsdxu/wrtrho + grav*dttdxu + grav*detadxu       &
               + grav*gosigu*oeu(1:ifull)*drhobardxu(:,ii)/wrtrho &
               + grav*rhobaru(1:ifull,ii)*detadxu/wrtrho ! staggered
    tav(:,ii) = grav*gosigv*ddv(1:ifull)*drhobardyv(:,ii)/wrtrho  &
               + dpsdyv/wrtrho + grav*dttdyv + grav*detadyv       &
               + grav*gosigv*oev(1:ifull)*drhobardyv(:,ii)/wrtrho &
               + grav*rhobarv(1:ifull,ii)*detadyv/wrtrho
    tau(:,ii) = tau(:,ii)*eeu(1:ifull,ii)
    tav(:,ii) = tav(:,ii)*eev(1:ifull,ii)
  end do
  select case(mlojacobi)
    case(6,7)
      do ii = 1,wlev
        depdum_rho(1:ifull+iextra) = gosig(1:ifull+iextra,ii)*dd(1:ifull+iextra)
        dzdxu = (depdum_rho(ie)-depdum_rho(1:ifull))*emu(1:ifull)*eeu(1:ifull,ii)/ds
        dzdyv = (depdum_rho(in)-depdum_rho(1:ifull))*emv(1:ifull)*eev(1:ifull,ii)/ds
        tau(:,ii) = tau(:,ii) + grav*rhobaru(1:ifull,ii)*dzdxu/wrtrho ! staggered
        tav(:,ii) = tav(:,ii) + grav*rhobarv(1:ifull,ii)*dzdyv/wrtrho
        tau(:,ii) = tau(:,ii)*eeu(1:ifull,ii)
        tav(:,ii) = tav(:,ii)*eev(1:ifull,ii)
      end do     
  end select    
  ! ice
  !tau(:,wlev+1)=grav*(neta_e-neta(1:ifull))*emu(1:ifull)/ds ! staggered
  !tav(:,wlev+1)=grav*(neta_n-neta(1:ifull))*emv(1:ifull)/ds
  call mlounstaguv(tau(:,1:wlev),tav(:,1:wlev),ttau(:,1:wlev),ttav(:,1:wlev),toff=1)
  ! ocean
  do ii = 1,wlev
    uau(:,ii) = nu(1:ifull,ii) + (1.-ocneps)*0.5*dt*( f(1:ifull)*nv(1:ifull,ii)-ttau(:,ii)) ! unstaggered
    uav(:,ii) = nv(1:ifull,ii) + (1.-ocneps)*0.5*dt*(-f(1:ifull)*nu(1:ifull,ii)-ttav(:,ii))
    uau(:,ii) = uau(:,ii)*ee(1:ifull,ii)
    uav(:,ii) = uav(:,ii)*ee(1:ifull,ii)
  end do
  ! ice
  snu(1:ifull) = i_u !-dt*ttau(:,wlev+1)
  snv(1:ifull) = i_v !-dt*ttav(:,wlev+1)
  

  ! Vertical advection (first call for 0.5*dt)
  call mlovadv(hdt,nw,uau,uav,ns,nt,mps,depdum,dzdum,wtr,1)

  
  workdata = nt(1:ifull,:)
  call mlocheck("first vertical advection",water_temp=workdata,water_u=uau,water_v=uav)


  ! Calculate depature points
  call mlodeps(nuh,nvh,nface,xg,yg,x3d,y3d,z3d,wtr)

  ! Convert (u,v) to cartesian coordinates (U,V,W)
  do ii = 1,wlev
    cou(1:ifull,ii,1) = ax(1:ifull)*uau(:,ii) + bx(1:ifull)*uav(:,ii)
    cou(1:ifull,ii,2) = ay(1:ifull)*uau(:,ii) + by(1:ifull)*uav(:,ii)
    cou(1:ifull,ii,3) = az(1:ifull)*uau(:,ii) + bz(1:ifull)*uav(:,ii)
  end do
  ! Horizontal advection for U, V, W
  call mlob2ints_bs(cou(:,:,1:3),nface,xg,yg,wtr)
  ! Rotate vector to arrival point
  call mlorot(cou(:,:,1),cou(:,:,2),cou(:,:,3),x3d,y3d,z3d)
  ! Convert (U,V,W) back to conformal cubic coordinates
  do ii = 1,wlev
    uau(:,ii) = ax(1:ifull)*cou(1:ifull,ii,1) + ay(1:ifull)*cou(1:ifull,ii,2) + az(1:ifull)*cou(1:ifull,ii,3)
    uav(:,ii) = bx(1:ifull)*cou(1:ifull,ii,1) + by(1:ifull)*cou(1:ifull,ii,2) + bz(1:ifull)*cou(1:ifull,ii,3)
    uau(:,ii) = uau(:,ii)*ee(1:ifull,ii)
    uav(:,ii) = uav(:,ii)*ee(1:ifull,ii)
  end do

  ! Horizontal advection for T, S and continuity
  do ii = 1,wlev
    cou(1:ifull,ii,1) = nt(1:ifull,ii)
    cou(1:ifull,ii,2) = ns(1:ifull,ii) - 34.72
    cou(1:ifull,ii,3) = mps(1:ifull,ii)
  end do
  call mlob2ints_bs(cou(:,:,1:3),nface,xg,yg,wtr)
  do ii = 1,wlev
    nt(1:ifull,ii) = max( cou(1:ifull,ii,1), -wrtemp )
    ns(1:ifull,ii) = max( cou(1:ifull,ii,2) + 34.72, 0. )
    mps(1:ifull,ii) = cou(1:ifull,ii,3)
  end do


  workdata = nt(1:ifull,:)
  call mlocheck("horizontal advection",water_temp=workdata,water_u=uau,water_v=uav)


  ! Vertical advection (second call for 0.5*dt)
  ! use explicit nw and depdum,dzdum from t=tau step (i.e., following JLM in CCAM atmospheric dynamics)
  ! Could use nuh and nvh to estimate nw at t+1/2, but also require an estimate of neta at t+1/2
  call mlovadv(hdt,nw,uau,uav,ns,nt,mps,depdum,dzdum,wtr,2)


  workdata = nt(1:ifull,:)
  call mlocheck("second vertical advection",water_temp=workdata,water_u=uau,water_v=uav)


  xps(:) = mps(1:ifull,1)*godsig(1:ifull,1)
  do ii = 2,wlev
    xps(:) = xps(:) + mps(1:ifull,ii)*godsig(1:ifull,ii)
  end do
  xps(:) = xps(:)*ee(1:ifull,1)
  

  call START_LOG(watereos_begin)

  ! Approximate normalised density rhobar at t+1 (unstaggered, using T and S at t+1)
  if ( nxtrrho==1 ) then
    call bounds(nt,corner=.true.)
    call bounds(ns,corner=.true.)
    ! update normalised density gradients
    call tsjacobi(nt,ns,pice,drhobardxu,drhobardyu,drhobardxv,drhobardyv,rhobar,rhobaru,rhobarv)
  end if

  call END_LOG(watereos_end)


  ! FREE SURFACE CALCULATION ----------------------------------------

  ! Precompute U,V current and integral terms at t+1
  ! ocean
  do ii = 1,wlev
    tau(:,ii) = uau(:,ii) + (1.+ocneps)*0.5*dt*f(1:ifull)*uav(:,ii) ! unstaggered
    tav(:,ii) = uav(:,ii) - (1.+ocneps)*0.5*dt*f(1:ifull)*uau(:,ii)
  end do
  ! ice
  tau(:,wlev+1) = snu(1:ifull) + dt*f(1:ifull)*snv(1:ifull) ! unstaggered
  tav(:,wlev+1) = snv(1:ifull) - dt*f(1:ifull)*snu(1:ifull)
  call mlostaguv(tau(:,1:wlev+1),tav(:,1:wlev+1),ttau(:,1:wlev+1),ttav(:,1:wlev+1))
  
  ! Set-up calculation of ocean and ice at t+1
  ! ocean
  odum = eeu(1:ifull,1)/(1.+((1.+ocneps)*0.5*dt*fu(1:ifull))**2)
  do ii = 1,wlev
    ccu(1:ifull,ii) = ttau(:,ii)*odum ! staggered
  end do
  odum = eev(1:ifull,1)/(1.+((1.+ocneps)*0.5*dt*fv(1:ifull))**2)
  do ii = 1,wlev
    ccv(1:ifull,ii) = ttav(:,ii)*odum ! staggered
  end do
  ! ice
  ! niu and niv hold the free drift solution (staggered).  Wind stress terms are updated in mlo.f90
  niu(1:ifull) = ttau(:,wlev+1)/(1.+(dt*fu(1:ifull))**2) ! staggered
  niv(1:ifull) = ttav(:,wlev+1)/(1.+(dt*fv(1:ifull))**2)
 
  
  ! calculate 5-point stencil
  bb(1:ifull) = -ee(1:ifull,1)*(1.+ocneps)*0.5*dt/(1.+((1.+ocneps)*0.5*dt*f(1:ifull))**2) ! unstaggered
  ibb(1:ifull) = -ee(1:ifull,1)*dt/(imass(1:ifull)*(1.+(dt*f(1:ifull))**2))  ! unstaggered
  do ii = 1,wlev
    cc(1:ifull,ii) = (1.+rhobar(1:ifull,ii)/wrtrho)*bb(1:ifull)*ee(1:ifull,ii)
  end do
  cc(1:ifull,wlev+1) = ibb(1:ifull)
  call bounds(cc(:,1:wlev+1),corner=.true.)
  ibb(ifull+1:ifull+iextra) = cc(ifull+1:ifull+iextra,wlev+1)

  ! ocean - recalculate bb with rhobar
  bb = 0.
  bb3u = 0.
  bb4v = 0.
  do ii = 1,wlev
    call unpack_nsew(cc(:,ii),cc_n,cc_s,cc_e,cc_w)
    do iq = 1,ifull
      tnu(iq) = 0.5*(1.+ocneps)*0.5*dt*( cc_n(iq)*f_n(iq) + cc(ien(iq),ii)*f(ien(iq)) )
      tsu(iq) = 0.5*(1.+ocneps)*0.5*dt*( cc_s(iq)*f_s(iq) + cc(ies(iq),ii)*f(ies(iq)) )
      tev(iq) = 0.5*(1.+ocneps)*0.5*dt*( cc_e(iq)*f_e(iq) + cc(ine(iq),ii)*f(ine(iq)) )
      twv(iq) = 0.5*(1.+ocneps)*0.5*dt*( cc_w(iq)*f_w(iq) + cc(inw(iq),ii)*f(inw(iq)) )
    end do
    bb(:) = bb(:) + cc(:,ii)*godsig(:,ii)
    bb3u(1:ifull) = bb3u(1:ifull) + ((cc_e-cc(1:ifull,ii))*emu(1:ifull)/ds*eeu(1:ifull,ii) &
        + 0.5*( tnu-tsu )*emu(1:ifull)/ds*stwgt(1:ifull,ii))*godsigu(1:ifull,ii)
    bb4v(1:ifull) = bb4v(1:ifull) + ((cc_n-cc(1:ifull,ii))*emv(1:ifull)/ds*eev(1:ifull,ii) &
        - 0.5*( tev-twv )*emv(1:ifull)/ds*stwgt(1:ifull,ii))*godsigv(1:ifull,ii)
  end do  

  do ii = 1,wlev
    ! Create arrays to calcuate u and v at t+1, based on pressure gradient at t+1
      
    ! ffu = (1.+ocneps)*0.5*dt*fu
    ! ffv = (1.+ocneps)*0.5*dt*fv     
    ! u^(t+1) = nu = ccu^(t*) + bu*dpdxu^(t+1)/wrtrho + bu*ffu*dpdyu^(t+1)/wrtrho (staggered)
    ! v^(t+1) = nv = ccv^(t*) + bv*dpdyv^(t+1)/wrtrho - bv*ffv*dpdxv^(t+1)/wrtrho (staggered)
      
    ! u^(t+1)*(1+(0.5*dt*f)^2) = [u + 0.5*dt*f*v - 0.5*dt/wrtrho*dpdx]^(t*) + 0.5*dt*f*[v - 0.5*dt*f*u - 0.5*dt/wrtrho*dpdy]^(t*)
    !                            - 0.5*dt/wrtrho*[dpdx + 0.5*dt*f*dpdy]^(t+1)     
    ! v^(t+1)*(1+(0.5*dt*f)^2) = [v - 0.5*dt*f*u - 0.5*dt/wrtrho*dpdy]^(t*) - 0.5*dt*f*[u + 0.5*dt*f*v - 0.5*dt/wrtrho*dpdx]^(t*)
    !                            - 0.5*dt/wrtrho*[dpdy - 0.5*dt*f*dpdx]^(t+1)
    
    ! dPdz = grav*rho
    ! dPdz* = grav*rho*(eta+D)/D
    ! P = grav*rhobar*(eta+D)*(z*)/D = grav*rhobar*(z+eta) = grav*rhobar*sig*(eta+D)
    ! dPdx = grav*sig*(eta+D)*d(rhobar)dx + grav*rhobar*d(eta)dx
    
    ! Note pressure gradients are along constant z surfaces
    ! p = ps + grav*wrtrho*tt + grav*sig*(dd+eta)*rhobar

    ! We use a modified form of JLM's trick where:
    !   a*dP/dx+a*F*dP/dy = d(aP)/dx + d(aFP)/dy - (da/dx+daF/dy)*P
    !   a*dP/dy-a*F*dP/dx = d(aP)/dy - d(aFP)/dx - (da/dy-daF/dx)*P
    !   F = (1+ocneps)*0.5*dt*f
    ! which produces a 5-point stencil when solving for neta and ip.
    
    !dpdxu=dpsdxu+grav*wrtrho*dttdxu+grav*sig*(ddu+etau)*drhobardxu+grav*rhobar*detadxu+grav*(rhobar-wrtrho)*dzdxu
    !dpdyu=dpsdyu+grav*wrtrho*dttdyu+grav*sig*(ddu+etau)*drhobardyu+grav*rhobar*detadyu+grav*(rhobar-wrtrho)*dzdyu
    !dpdxv=dpsdxv+grav*wrtrho*dttdxv+grav*sig*(ddv+etav)*drhobardxv+grav*rhobar*detadxv+grav*(rhobar-wrtrho)*dzdxv
    !dpdyv=dpsdyv+grav*wrtrho*dttdyv+grav*sig*(ddv+etav)*drhobardyv+grav*rhobar*detadyv+grav*(rhobar-wrtrho)*dzdyv

    ! Create arrays for u and v at t+1 in terms of neta gradients
    
    ! nu = kku + oou*etau + grav*lbu*detadxu + grav*lcu*detadyu   (staggered)
    ! nv = kkv + oov*etav + grav*lbv*detadyv + grav*lcv*detadxv   (staggered)
    
    call unpack_ne(gosig(:,ii),gosig_n,gosig_e)  
    gosigu = 0.5*(gosig(1:ifull,ii)+gosig_e)
    gosigv = 0.5*(gosig(1:ifull,ii)+gosig_n)
        
    kku(:,ii) = ccu(1:ifull,ii) + bu*(dpsdxu/wrtrho+grav*dttdxu) + cu*(dpsdyu/wrtrho+grav*dttdyu) &
              + grav*gosigu*ddu(1:ifull)*(bu*drhobardxu(:,ii)/wrtrho + cu*drhobardyu(:,ii)/wrtrho)
    oou(:,ii) = grav*gosigu*(bu*drhobardxu(:,ii)/wrtrho + cu*drhobardyu(:,ii)/wrtrho)
    
    kkv(:,ii) = ccv(1:ifull,ii) + bv*(dpsdyv/wrtrho+grav*dttdyv) + cv*(dpsdxv/wrtrho+grav*dttdxv) &
              + grav*gosigv*ddv(1:ifull)*(bv*drhobardyv(:,ii)/wrtrho + cv*drhobardxv(:,ii)/wrtrho)   
    oov(:,ii) = grav*gosigv*(bv*drhobardyv(:,ii)/wrtrho + cv*drhobardxv(:,ii)/wrtrho)
    
    kku(:,ii) = kku(:,ii)*eeu(1:ifull,ii)
    oou(:,ii) = oou(:,ii)*eeu(1:ifull,ii)
    kkv(:,ii) = kkv(:,ii)*eev(1:ifull,ii)
    oov(:,ii) = oov(:,ii)*eev(1:ifull,ii)
    
  end do
  
  select case(mlojacobi)
    case(6,7)
      do ii = 1,wlev   
        depdum_rho(1:ifull+iextra) = gosig(1:ifull+iextra,ii)*dd(1:ifull+iextra)
        do iq = 1,ifull
          tnu(iq) = 0.5*( depdum_rho(in(iq)) + depdum_rho(ien(iq)) )
          tsu(iq) = 0.5*( depdum_rho(is(iq)) + depdum_rho(ies(iq)) )
          tev(iq) = 0.5*( depdum_rho(ie(iq)) + depdum_rho(ine(iq)) )
          twv(iq) = 0.5*( depdum_rho(iw(iq)) + depdum_rho(inw(iq)) )
        end do  
        dzdxu = (depdum_rho(ie)-depdum_rho(1:ifull))*emu(1:ifull)*eeu(1:ifull,ii)/ds
        dzdyu = 0.5*stwgt(1:ifull,ii)*(tnu-tsu)*emu(1:ifull)/ds
        dzdxv = 0.5*stwgt(1:ifull,ii)*(tev-twv)*emv(1:ifull)/ds
        dzdyv = (depdum_rho(in)-depdum_rho(1:ifull))*emv(1:ifull)*eev(1:ifull,ii)/ds
        kku(:,ii) = kku(:,ii) + bu*grav*rhobaru(:,ii)*dzdxu/wrtrho + cu*grav*rhobaru(:,ii)*dzdyu/wrtrho   
        kkv(:,ii) = kkv(:,ii) + bv*grav*rhobarv(:,ii)*dzdyv/wrtrho + cv*grav*rhobarv(:,ii)*dzdxv/wrtrho
        kku(:,ii) = kku(:,ii)*eeu(1:ifull,ii)
        kkv(:,ii) = kkv(:,ii)*eev(1:ifull,ii)   
      end do  
  end select
      
  ! Pre-integrate arrays for u and v at t+1 (i.e., for calculating net divergence at t+1)
  
  !sum nu dz = sou+snu+grav*lbu*detadxu+grav*lcu*detadyu
  !sum nv dz = sov+snv+grav*lbv*detadyv+grav*lcv*detadxv

  sou = 0.
  sov = 0.
  snu = 0.
  snv = 0.
  do ii = 1,wlev
    sou(1:ifull) = sou(1:ifull) + kku(:,ii)*godsigu(1:ifull,ii)
    snu(1:ifull) = snu(1:ifull) + oou(:,ii)*godsigu(1:ifull,ii)
    sov(1:ifull) = sov(1:ifull) + kkv(:,ii)*godsigv(1:ifull,ii)
    snv(1:ifull) = snv(1:ifull) + oov(:,ii)*godsigv(1:ifull,ii)
  end do
  
  
  ! calculate terms for ice velocity at t+1

  ! (staggered)
  ! niu(t+1) = niu + ibu*dipdx + ibu*dt*fu*dipdy
  ! niv(t+1) = niv + ibv*dipdy - ibv*dt*fv*dipdx

  call unpack_nsew(ibb,ibb_n,ibb_s,ibb_e,ibb_w)
  do iq = 1,ifull
    tnu(iq) = 0.5*dt*( ibb_n(iq)*f_n(iq) + ibb(ien(iq))*f(ien(iq)) )
    tsu(iq) = 0.5*dt*( ibb_s(iq)*f_s(iq) + ibb(ies(iq))*f(ies(iq)) )
    tev(iq) = 0.5*dt*( ibb_e(iq)*f_e(iq) + ibb(ine(iq))*f(ine(iq)) )
    twv(iq) = 0.5*dt*( ibb_w(iq)*f_w(iq) + ibb(inw(iq))*f(inw(iq)) )
  end do
  ibb3u(1:ifull) = (ibb_e-ibb(1:ifull))*emu(1:ifull)/ds + 0.5*( tnu-tsu )*emu(1:ifull)/ds
  ibb4v(1:ifull) = (ibb_n-ibb(1:ifull))*emv(1:ifull)/ds - 0.5*( tev-twv )*emv(1:ifull)/ds
  ibb3u(1:ifull) = ibb3u(1:ifull)*stwgt(1:ifull,1)
  ibb4v(1:ifull) = ibb4v(1:ifull)*stwgt(1:ifull,1)

  
  ! update boundary
  data_c(1:ifull,1) = sou(1:ifull)
  data_d(1:ifull,1) = sov(1:ifull)
  data_c(1:ifull,2) = snu(1:ifull)
  data_d(1:ifull,2) = snv(1:ifull) 
  data_c(1:ifull,3) = bb3u(1:ifull)
  data_d(1:ifull,3) = bb4v(1:ifull)
  data_c(1:ifull,4) = ibb3u(1:ifull)
  data_d(1:ifull,4) = ibb4v(1:ifull)
  data_c(1:ifull,5) = niu(1:ifull)
  data_d(1:ifull,5) = niv(1:ifull)
  call boundsuv(data_c(:,1:5),data_d(:,1:5),stag=-9) ! stag=-9 updates iwu and isv
  sou(ifull+1:ifull+iextra) = data_c(ifull+1:ifull+iextra,1)
  sov(ifull+1:ifull+iextra) = data_d(ifull+1:ifull+iextra,1)
  snu(ifull+1:ifull+iextra) = data_c(ifull+1:ifull+iextra,2)
  snv(ifull+1:ifull+iextra) = data_d(ifull+1:ifull+iextra,2)
  bb3u(ifull+1:ifull+iextra) = data_c(ifull+1:ifull+iextra,3)
  bb4v(ifull+1:ifull+iextra) = data_d(ifull+1:ifull+iextra,3)
  ibb3u(ifull+1:ifull+iextra) = data_c(ifull+1:ifull+iextra,4)
  ibb4v(ifull+1:ifull+iextra) = data_d(ifull+1:ifull+iextra,4)
  niu(ifull+1:ifull+iextra) = data_c(ifull+1:ifull+iextra,5)
  niv(ifull+1:ifull+iextra) = data_d(ifull+1:ifull+iextra,5)

  ! Iteratively solve for free surface height, eta
  ! Iterative loop to estimate ice 'pressure'
  if ( precon<-9999 ) then
    ! Multi-grid
    call mlomg(neta,sou,sov,snu,snv,xps,bb,bb3u,bb4v,ipice,niu,niv,ibb,ibb3u,ibb4v, &
               ipmax,totits,maxglobseta,maxglobip)
  else
    ! Usual SOR
    write(6,*) "ERROR: MLO dynamics requires precon=-10000"
    call ccmpi_abort(-1)
  end if
  
  
  ! update bounds for solution to neta and ipice
  data_c(1:ifull,1) = neta(1:ifull)
  data_c(1:ifull,2) = ipice(1:ifull)
  call bounds(data_c(:,1:2),corner=.true.)
  neta(ifull+1:ifull+iextra)  = data_c(ifull+1:ifull+iextra,1)
  ipice(ifull+1:ifull+iextra) = data_c(ifull+1:ifull+iextra,2)
  call unpack_nsew(neta,neta_n,neta_s,neta_e,neta_w)
  call unpack_nsew(ipice,ipice_n,ipice_s,ipice_e,ipice_w)
  
  
  ! Update currents once neta is calculated
  do iq = 1,ifull
    tnu(iq) = 0.5*( neta_n(iq) + neta(ien(iq)) )
    tsu(iq) = 0.5*( neta_s(iq) + neta(ies(iq)) )
    tev(iq) = 0.5*( neta_e(iq) + neta(ine(iq)) )
    twv(iq) = 0.5*( neta_w(iq) + neta(inw(iq)) )
  end do  
  detadxu = (neta_e-neta(1:ifull))*emu(1:ifull)/ds
  detadyu = 0.5*stwgt(1:ifull,1)*(tnu-tsu)*emu(1:ifull)/ds
  detadxv = 0.5*stwgt(1:ifull,1)*(tev-twv)*emv(1:ifull)/ds
  detadyv = (neta_n-neta(1:ifull))*emv(1:ifull)/ds 
  oeu(1:ifull) = 0.5*(neta_e+neta(1:ifull))*eeu(1:ifull,1)
  oev(1:ifull) = 0.5*(neta_n+neta(1:ifull))*eev(1:ifull,1)
  do ii = 1,wlev
    ! update currents (staggered)
    call unpack_ne(cc(:,ii),cc_n,cc_e)
    lbu = 0.5*(cc(1:ifull,ii)+cc_e)*eeu(1:ifull,ii)
    lbv = 0.5*(cc(1:ifull,ii)+cc_n)*eev(1:ifull,ii)
    lcu =  lbu*(1.+ocneps)*0.5*dt*fu
    lcv = -lbv*(1.+ocneps)*0.5*dt*fv
    nu(1:ifull,ii) = kku(:,ii) + oou(:,ii)*oeu(1:ifull) + grav*lbu*detadxu + grav*lcu*detadyu
    nv(1:ifull,ii) = kkv(:,ii) + oov(:,ii)*oev(1:ifull) + grav*lbv*detadyv + grav*lcv*detadxv
  end do 
  
  
  worku = nu(1:ifull,:)
  workv = nv(1:ifull,:)
  call mlocheck("solver",water_u=worku,water_v=workv)


  call START_LOG(wateriadv_begin)

  ! Update ice velocity with internal pressure terms
  do iq = 1,ifull
    tnu(iq) = 0.5*( ipice_n(iq)+ipice(ien(iq)) )
    tsu(iq) = 0.5*( ipice_s(iq)+ipice(ies(iq)) )
    tev(iq) = 0.5*( ipice_e(iq)+ipice(ine(iq)) )
    twv(iq) = 0.5*( ipice_w(iq)+ipice(inw(iq)) )
  end do  
  dipdxu = (ipice_e-ipice(1:ifull))*emu(1:ifull)/ds
  dipdyu = 0.5*stwgt(1:ifull,1)*(tnu-tsu)*emu(1:ifull)/ds
  dipdxv = 0.5*stwgt(1:ifull,1)*(tev-twv)*emv(1:ifull)/ds
  dipdyv = (ipice_n-ipice(1:ifull))*emv(1:ifull)/ds
  ibu = 0.5*(ibb(1:ifull)+ibb_e)
  ibv = 0.5*(ibb(1:ifull)+ibb_n)
  niu(1:ifull) = niu(1:ifull) + ibu*dipdxu + ibu*dt*fu(1:ifull)*dipdyu
  niv(1:ifull) = niv(1:ifull) + ibv*dipdyv - ibv*dt*fv(1:ifull)*dipdxv
  niu(1:ifull) = niu(1:ifull)*eeu(1:ifull,1)
  niv(1:ifull) = niv(1:ifull)*eev(1:ifull,1)
  call boundsuv(niu,niv,stag=-9)

  ! Normalisation factor for conserving ice flow in and out of gridbox
  call unpack_svwu(niu,niv,ni_isv,ni_iwu)
  spnet(1:ifull) = (-min(ni_iwu*em_iwu,0.)+max(niu(1:ifull)*emu(1:ifull),0.)     &
                    -min(ni_isv*em_isv,0.)+max(niv(1:ifull)*emv(1:ifull),0.))/ds


  ! ADVECT ICE ------------------------------------------------------
  ! use simple upwind scheme

  ! Horizontal advection for ice area
  data_c(1:ifull,1) = fracice/(em(1:ifull)**2)             ! data_c(:,1) is an area
  ! Horizontal advection for ice volume
  data_c(1:ifull,2) = sicedep*fracice/(em(1:ifull)**2)     ! data_c(:,2) is a volume
  ! Horizontal advection for snow volume
  data_c(1:ifull,3) = snowd*0.001*fracice/(em(1:ifull)**2) ! data_c(:,3) is a volume
  ! Horizontal advection for ice energy store
  data_c(1:ifull,4) = i_sto*fracice/(em(1:ifull)**2)
  ndsn(1:ifull) = snowd(1:ifull)*0.001
  call mloexpgamm(gamm,sicedep,ndsn(1:ifull),0)
  ! Horizontal advection for surface temperature
  data_c(1:ifull,5) = i_it(1:ifull,1)*fracice*gamm(:,1)/(em(1:ifull)**2)
  ! Horizontal advection of snow temperature
  data_c(1:ifull,6) = i_it(1:ifull,2)*fracice*gamm(:,2)/(em(1:ifull)**2)
  ! Horizontal advection of ice temperatures
  data_c(1:ifull,7) = i_it(1:ifull,3)*fracice*gamm(:,3)/(em(1:ifull)**2)
  data_c(1:ifull,8) = i_it(1:ifull,4)*fracice*gamm(:,3)/(em(1:ifull)**2) 
  ! Conservation
  data_c(1:ifull,9) = spnet(1:ifull)
  call bounds(data_c(:,1:9))
  spnet(ifull+1:ifull+iextra) = data_c(ifull+1:ifull+iextra,9)
  do ii = 1,8
    call upwind_iceadv(data_c(:,ii),niu,niv,spnet)
  end do  
  nfracice(1:ifull) = min( max( data_c(1:ifull,1)*em(1:ifull)**2, 0. ), maxicefrac )
  ndic(1:ifull) = data_c(1:ifull,2)*em(1:ifull)**2/max(nfracice(1:ifull),1.E-10)
  ndsn(1:ifull) = data_c(1:ifull,3)*em(1:ifull)**2/max(nfracice(1:ifull),1.E-10)
  nsto(1:ifull) = data_c(1:ifull,4)*em(1:ifull)**2/max(nfracice(1:ifull),1.E-10)
  call mloexpgamm(gamm,ndic,ndsn,0)
  nit(1:ifull,1) = data_c(1:ifull,5)*em(1:ifull)**2/max(gamm(:,1)*nfracice(1:ifull),1.E-10)
  nit(1:ifull,2) = data_c(1:ifull,6)*em(1:ifull)**2/max(gamm(:,2)*nfracice(1:ifull),1.E-10)
  nit(1:ifull,3) = data_c(1:ifull,7)*em(1:ifull)**2/max(gamm(:,3)*nfracice(1:ifull),1.E-10)
  nit(1:ifull,4) = data_c(1:ifull,8)*em(1:ifull)**2/max(gamm(:,3)*nfracice(1:ifull),1.E-10)

  ! populate grid points that have no sea ice
  where ( nfracice(1:ifull)<1.E-4 .or. ndic(1:ifull)<1.E-4 )
    nfracice(1:ifull) = 0.
    ndic(1:ifull) = 0.
    ndsn(1:ifull) = 0.
    nsto(1:ifull) = 0.
    nit(1:ifull,1) = 273.16
    nit(1:ifull,2) = 273.16
    nit(1:ifull,3) = 273.16
    nit(1:ifull,4) = 273.16
  elsewhere ( ndsn(1:ifull)<1.E-4 )
    ndsn(1:ifull) = 0.
    nit(1:ifull,2) = 273.16
  end where

  
  call mlocheck("seaice advection",ice_tsurf=nit(1:ifull,1))
  
  
  ! unstagged currents and ice velocity
  ttau(:,1:wlev) = nu(1:ifull,:)
  ttav(:,1:wlev) = nv(1:ifull,:)
  ttau(:,wlev+1) = niu(1:ifull)
  ttav(:,wlev+1) = niv(1:ifull)
  call mlounstaguv(ttau(:,1:wlev+1),ttav(:,1:wlev+1),tau(:,1:wlev+1),tav(:,1:wlev+1))
  nu(1:ifull,:) = tau(:,1:wlev)
  nv(1:ifull,:) = tav(:,1:wlev)
  niu(1:ifull) = tau(:,wlev+1)
  niv(1:ifull) = tav(:,wlev+1)
  
  call END_LOG(wateriadv_end)

  
  call START_LOG(watermfix_begin)

  ! volume conservation for water
  if ( nud_sfh==0 ) then
    ! this is a mfix=1 method.  mfix=3 may not be viable for neta  
    delpos(1) = 0.
    delneg(1) = 0.
    select case(mlomfix)
      case(1,2)
        neta(1:ifull) = max(min(neta(1:ifull), 130.), -130.)
        odum = (neta(1:ifull)-w_e)*ee(1:ifull,1)
        call ccglobal_posneg(odum,delpos(1),delneg(1))
        alph_p = sqrt(-delneg(1)/max(delpos(1),1.e-20))
        if ( abs(alph_p)>1.e-20 ) then
          neta(1:ifull) = w_e(1:ifull) + max(0.,odum)*alph_p + min(0.,odum)/alph_p
        end if
      case default
        neta(1:ifull) = max(min(neta(1:ifull), 130.), -130.)
    end select
    if ( nodrift==1 ) then
      odum = neta(1:ifull)*ee(1:ifull,1)*em(1:ifull)**2
      call mlosum(odum,lsum)
      call ccmpi_allreduce(lsum,gsum,"sumdr",comm_world)
      delta = real(gsum)/real(emsum)
      neta(1:ifull) = (neta(1:ifull) - delta)*ee(1:ifull,1)
    end if
  end if

  ! temperature conservation (usually off when nudging SSTs)
  if ( nud_sst==0 ) then
    delpos(1) = 0.
    delneg(1) = 0.
    select case( mlomfix )
      case(1)  ! no free surface
        do ii = 1,wlev
          nt(1:ifull,ii) = min( max( nt(1:ifull,ii), 150.-wrtemp ), 375.-wrtemp )
          mfixdum(:,ii) = (nt(1:ifull,ii)-w_t(:,ii))*dd(1:ifull)*ee(1:ifull,ii)
        end do
        call ccglobal_posneg(mfixdum,delpos(1),delneg(1),godsig)
        alph_p = sqrt(-delneg(1)/max(delpos(1),1.e-20))
        do ii = 1,wlev
          where(wtr(1:ifull,ii) .and. abs(alph_p)>1.e-20)
            nt(1:ifull,ii) = w_t(1:ifull,ii)                                              &
                             +(max(0.,mfixdum(:,ii))*alph_p+min(0.,mfixdum(:,ii))/alph_p) &
                             /dd(1:ifull)
          elsewhere
            nt(1:ifull,ii) = w_t(:,ii)              
          end where
        end do  
      case(2)  ! include free surface
        do ii = 1,wlev
          nt(1:ifull,ii) = min( max( nt(1:ifull,ii), 150.-wrtemp ), 375.-wrtemp )
          mfixdum(:,ii) = (nt(1:ifull,ii)-w_t(:,ii))*max(dd(1:ifull)+w_e(1:ifull),minwater)*ee(1:ifull,ii)
        end do
        call ccglobal_posneg(mfixdum,delpos(1),delneg(1),godsig)
        alph_p = sqrt(-delneg(1)/max(delpos(1),1.e-20))
        do ii = 1,wlev
          where(wtr(1:ifull,ii) .and. abs(alph_p)>1.e-20)
            nt(1:ifull,ii) = w_t(1:ifull,ii)                                              &
                             +(max(0.,mfixdum(:,ii))*alph_p+min(0.,mfixdum(:,ii))/alph_p) &
                             /max(dd(1:ifull)+w_e(1:ifull),minwater)
          elsewhere
            nt(1:ifull,ii) = w_t(:,ii)              
          end where
        end do  
      case default  
        do ii = 1,wlev
          nt(1:ifull,ii) = min( max( nt(1:ifull,ii), 150.-wrtemp ), 375.-wrtemp )
        end do  
    end select
    
    workdata = nt(1:ifull,:)
    call mlocheck("conservation fix",water_temp=workdata)
    
  end if

  ! salinity conservation
  if ( nud_sss==0 ) then
    delpos(1) = 0.
    delneg(1) = 0.
    select case( mlomfix )
      case(1)
        do ii = 1,wlev
          ns(1:ifull,ii) = max( ns(1:ifull,ii), 0. )  
          mfixdum(:,ii) = (ns(1:ifull,ii)-w_s(:,ii))*dd(1:ifull)*ee(1:ifull,ii)
        end do
        call ccglobal_posneg(mfixdum,delpos(1),delneg(1),godsig)
        alph_p = sqrt(-delneg(1)/max(delpos(1),1.e-20))
        do ii = 1,wlev
          where( wtr(1:ifull,ii) .and. abs(alph_p)>1.e-20 )    
            ns(1:ifull,ii) = w_s(1:ifull,ii)                                            &
                           +(max(0.,mfixdum(:,ii))*alph_p+min(0.,mfixdum(:,ii))/alph_p) &
                           /dd(1:ifull)
          elsewhere
            ns(1:ifull,ii) = w_s(:,ii)              
          end where
        end do  
      case(2)
        do ii = 1,wlev
          ns(1:ifull,ii) = max( ns(1:ifull,ii), 0. )  
          mfixdum(:,ii) = (ns(1:ifull,ii)-w_s(:,ii))*max(dd(1:ifull)+w_e(1:ifull),minwater)*ee(1:ifull,ii)
        end do
        call ccglobal_posneg(mfixdum,delpos(1),delneg(1),godsig)
        alph_p = sqrt(-delneg(1)/max(delpos(1),1.e-20))
        do ii = 1,wlev
          where( wtr(1:ifull,ii) .and. abs(alph_p)>1.e-20 )    
            ns(1:ifull,ii) = w_s(1:ifull,ii)                                            &
                           +(max(0.,mfixdum(:,ii))*alph_p+min(0.,mfixdum(:,ii))/alph_p) &
                           /max(dd(1:ifull)+w_e(1:ifull),minwater)
          elsewhere
            ns(1:ifull,ii) = w_s(:,ii)              
          end where
        end do            
      case default
        do ii = 1,wlev
          ns(1:ifull,ii) = max( ns(1:ifull,ii), 0. )  
        end do  
    end select
    !if ( nodrift==1 ) then
    !  odum = (ns(1:ifull,1)-34.7)*ee(1:ifull,1)*em(1:ifull)**2
    !  call mlosum(odum,lsum)
    !  call ccmpi_allreduce(lsum,gsum,"sumdr",comm_world)
    !  delta = real(gsum)/real(emsum)
    !  ns(1:ifull,1) = (ns(1:ifull,1) - delta)*ee(1:ifull,1)
    !  ns(1:ifull,1) = max( ns(1:ifull,1), 0. )
    !end if
  end if

  if ( myid==0 .and. (ktau<=5.or.maxglobseta>tol.or.maxglobip>itol) ) then
    write(6,*) "MLODYNAMICS ",totits,maxglobseta,maxglobip
  end if

  call END_LOG(watermfix_end)


  ! reset time-step
  dt = dtin_mlo

end do ! mspec_mlo


w_u = nu(1:ifull,:)
w_v = nv(1:ifull,:)
w_t = nt(1:ifull,:)
w_s = ns(1:ifull,:)
call mlocheck("end of mlodynamics",water_u=w_u,water_v=w_v,ice_tsurf=nit(1:ifull,1))

call mlodiffusion_work(w_u,w_v,w_t,w_s)

! STORE WATER AND ICE DATA IN MLO ------------------------------------------
call mloimport(4,neta(1:ifull),0,0)
call mloimport3d(0,w_t,0)
call mloimport3d(1,w_s,0)
call mloimport3d(2,w_u,0)
call mloimport3d(3,w_v,0)
do ii = 1,4
  call mloimpice(nit(1:ifull,ii),ii,0)
end do
call mloimpice(nfracice(1:ifull),5,0)
call mloimpice(ndic(1:ifull),6,0)
call mloimpice(ndsn(1:ifull),7,0)
call mloimpice(nsto(1:ifull),8,0)
call mloimpice(niu(1:ifull),9,0)
call mloimpice(niv(1:ifull),10,0)
where ( wtr(1:ifull,1) )
  fracice = nfracice(1:ifull)
  sicedep = ndic(1:ifull)
  snowd = ndsn(1:ifull)*1000.
end where

return
end subroutine mlohadv

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Calculate depature points for MLO semi-Lagrangian advection
! (This subroutine is based on depts.f)

subroutine mlodeps(ubar,vbar,nface,xg,yg,x3d,y3d,z3d,wtr)

use cc_mpi
use const_phys
use indices_m
use mlo
use newmpar_m
use parm_m
use parmhor_m
use vecsuv_m
use xyzinfo_m

implicit none

integer iq,i,j,k,n,nn,idel,jdel,intsch,ii
integer, dimension(ifull,wlev), intent(out) :: nface
integer s_count
real, dimension(ifull,wlev), intent(in) :: ubar,vbar
real, dimension(ifull,wlev), intent(out) :: xg,yg
real(kind=8), dimension(ifull,wlev), intent(out) :: x3d,y3d,z3d
real, dimension(ifull,wlev) :: uc,vc,wc
real, dimension(ifull+iextra,wlev,3) :: s, s_old
real, dimension(-1:ipan+2,-1:jpan+2,1:npan,wlev,3) :: sx
real s_tot, s_test
real dmul_2, dmul_3, cmul_1, cmul_2, cmul_3, cmul_4
real emul_1, emul_2, emul_3, emul_4, rmul_1, rmul_2, rmul_3, rmul_4
real xxg,yyg
real, parameter :: cxx = -9999. ! missing value flag
logical, dimension(ifull+iextra,wlev), intent(in) :: wtr

call START_LOG(waterdeps_begin)

! departure point x, y, z is called x3d, y3d, z3d
! first find corresponding cartesian vels
do k = 1,wlev
  uc(:,k) = (ax(1:ifull)*ubar(:,k)+bx(1:ifull)*vbar(:,k))*dt/rearth ! unit sphere 
  vc(:,k) = (ay(1:ifull)*ubar(:,k)+by(1:ifull)*vbar(:,k))*dt/rearth ! unit sphere 
  wc(:,k) = (az(1:ifull)*ubar(:,k)+bz(1:ifull)*vbar(:,k))*dt/rearth ! unit sphere 
  x3d(:,k) = x - uc(:,k) ! 1st guess
  y3d(:,k) = y - vc(:,k)
  z3d(:,k) = z - wc(:,k)
end do

! convert to grid point numbering
call mlotoij5(x3d,y3d,z3d,nface,xg,yg)

! Share off processor departure points.
call deptsync(nface,xg,yg)

intsch = mod(ktau,2)

do k = 1,wlev
  where (wtr(1:ifull,k))
    s(1:ifull,k,1) = uc(1:ifull,k) 
    s(1:ifull,k,2) = vc(1:ifull,k)
    s(1:ifull,k,3) = wc(1:ifull,k)
  else where    
    s(1:ifull,k,1) = cxx - 1. ! missing value flag
    s(1:ifull,k,2) = cxx - 1.
    s(1:ifull,k,3) = cxx - 1.
  end where
end do

! fill
do ii = 1,3 ! 3 iterations of fill should be enough
  s_old(1:ifull,:,:) = s(1:ifull,:,:)
  call bounds(s_old)
  do concurrent (nn = 1:3)
    do concurrent (k = 1:wlev)
      do concurrent (iq = 1:ifull)
        if ( s(iq,k,nn)<cxx ) then
          s_tot = 0.
          s_count = 0
          s_test = s_old(is(iq),k,nn)
          if ( s_test>cxx ) then
            s_tot = s_tot + s_test
            s_count = s_count +1
          end if
          s_test = s_old(in(iq),k,nn)
          if ( s_test>cxx ) then
            s_tot = s_tot + s_test
            s_count = s_count +1
          end if 
          s_test = s_old(ie(iq),k,nn)
          if ( s_test>cxx ) then
            s_tot = s_tot + s_test
            s_count = s_count +1
          end if
          s_test = s_old(iw(iq),k,nn)
          if ( s_test>cxx ) then
            s_tot = s_tot + s_test
            s_count = s_count +1
          end if
          if ( s_count>0 ) then
            s(iq,k,nn) = s_tot/real(s_count)
          end if
        end if
      end do
    end do
  end do
end do

call bounds(s,nrows=2)

!$acc data create(xg,yg,nface,sx,s)
!$acc update device(xg,yg,nface)

!======================== start of intsch=1 section ====================
if ( intsch==1 ) then

  sx(1:ipan,1:jpan,1:npan,1:wlev,1:3) = reshape( s(1:ipan*jpan*npan,1:wlev,1:3), (/ ipan, jpan, npan, wlev, 3 /) )
  do nn = 1,3
    do k = 1,wlev
      do n = 1,npan
        do j = 1,jpan
          iq = 1+(j-1)*ipan+(n-1)*ipan*jpan
          sx(0,j,n,k,nn)      = s( iw(iq),k,nn)
          sx(-1,j,n,k,nn)     = s(iww(iq),k,nn)
          iq = j*ipan+(n-1)*ipan*jpan
          sx(ipan+1,j,n,k,nn) = s( ie(iq),k,nn)
          sx(ipan+2,j,n,k,nn) = s(iee(iq),k,nn)
        end do
        do i = 1,ipan
          iq = i+(n-1)*ipan*jpan
          sx(i,0,n,k,nn)      = s( is(iq),k,nn)
          sx(i,-1,n,k,nn)     = s(iss(iq),k,nn)
          iq = i-ipan+n*ipan*jpan
          sx(i,jpan+1,n,k,nn) = s( in(iq),k,nn)
          sx(i,jpan+2,n,k,nn) = s(inn(iq),k,nn)
        end do
      end do
      do n = 1,npan
        sx(-1,0,n,k,nn)          = s(lwws(n),k,nn)
        sx(0,0,n,k,nn)           = s(iws(1+(n-1)*ipan*jpan),   k,nn)
        sx(0,-1,n,k,nn)          = s(lwss(n),k,nn)
        sx(ipan+1,0,n,k,nn)      = s(ies(ipan+(n-1)*ipan*jpan),k,nn)
        sx(ipan+2,0,n,k,nn)      = s(lees(n),k,nn)
        sx(ipan+1,-1,n,k,nn)     = s(less(n),k,nn)
        sx(-1,jpan+1,n,k,nn)     = s(lwwn(n),k,nn)
        sx(0,jpan+2,n,k,nn)      = s(lwnn(n),k,nn)
        sx(ipan+2,jpan+1,n,k,nn) = s(leen(n),k,nn)
        sx(ipan+1,jpan+2,n,k,nn) = s(lenn(n),k,nn)
        sx(0,jpan+1,n,k,nn)      = s(iwn(1-ipan+n*ipan*jpan),k,nn)
        sx(ipan+1,jpan+1,n,k,nn) = s(ien(n*ipan*jpan),       k,nn)
      end do               ! n loop
    end do                 ! k loop
  end do                   ! nn loop

  !$acc update device(sx)
 
! Loop over points that need to be calculated for other processes
  do ii = neighnum,1,-1
    do nn = 1,3
      do iq = 1,drlen(ii)
        n = nint(dpoints(ii)%a(1,iq)) + noff ! Local index
        !  Need global face index in fproc call
        idel = int(dpoints(ii)%a(2,iq))
        xxg = dpoints(ii)%a(2,iq) - real(idel)
        jdel = int(dpoints(ii)%a(3,iq))
        yyg = dpoints(ii)%a(3,iq) - real(jdel)
        k = nint(dpoints(ii)%a(4,iq))
        idel = idel - ioff
        jdel = jdel - joff
        ! bi-cubic interpolation
        cmul_1 = (1.-xxg)*(2.-xxg)*(-xxg)/6.
        cmul_2 = (1.-xxg)*(2.-xxg)*(1.+xxg)/2.
        cmul_3 = xxg*(1.+xxg)*(2.-xxg)/2.
        cmul_4 = (1.-xxg)*(-xxg)*(1.+xxg)/6.
        dmul_2 = (1.-xxg)
        dmul_3 = xxg
        emul_1 = (1.-yyg)*(2.-yyg)*(-yyg)/6.
        emul_2 = (1.-yyg)*(2.-yyg)*(1.+yyg)/2.
        emul_3 = yyg*(1.+yyg)*(2.-yyg)/2.
        emul_4 = (1.-yyg)*(-yyg)*(1.+yyg)/6.
        rmul_1 = sx(idel,  jdel-1,n,k,nn)*dmul_2 + sx(idel+1,jdel-1,n,k,nn)*dmul_3
        rmul_2 = sx(idel-1,jdel,  n,k,nn)*cmul_1 + sx(idel,  jdel,  n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel,  n,k,nn)*cmul_3 + sx(idel+2,jdel,  n,k,nn)*cmul_4
        rmul_3 = sx(idel-1,jdel+1,n,k,nn)*cmul_1 + sx(idel,  jdel+1,n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel+1,n,k,nn)*cmul_3 + sx(idel+2,jdel+1,n,k,nn)*cmul_4
        rmul_4 = sx(idel,  jdel+2,n,k,nn)*dmul_2 + sx(idel+1,jdel+2,n,k,nn)*dmul_3
        sextra(ii)%a(iq+(nn-1)*drlen(ii)) = rmul_1*emul_1 + rmul_2*emul_2 + rmul_3*emul_3 + rmul_4*emul_4
      end do          ! iq loop
    end do            ! nn loop
  end do              ! ii loop
  
  call intssync_send(3)

  !$acc parallel loop collapse(3) present(xg,yg,nface,sx,s)
  do concurrent (nn = 1:3)
    do concurrent (k = 1:wlev)
      do concurrent (iq = 1:ifull)
        idel = int(xg(iq,k))
        xxg  = xg(iq,k) - real(idel)
        jdel = int(yg(iq,k))
        yyg  = yg(iq,k) - real(jdel)
        idel = min( max( idel - ioff, 0), ipan )
        jdel = min( max( jdel - joff, 0), jpan )
        n = min( max( nface(iq,k) + noff, 1), npan )
        ! bi-cubic interpolation
        cmul_1 = (1.-xxg)*(2.-xxg)*(-xxg)/6.
        cmul_2 = (1.-xxg)*(2.-xxg)*(1.+xxg)/2.
        cmul_3 = xxg*(1.+xxg)*(2.-xxg)/2.
        cmul_4 = (1.-xxg)*(-xxg)*(1.+xxg)/6.
        dmul_2 = (1.-xxg)
        dmul_3 = xxg
        emul_1 = (1.-yyg)*(2.-yyg)*(-yyg)/6.
        emul_2 = (1.-yyg)*(2.-yyg)*(1.+yyg)/2.
        emul_3 = yyg*(1.+yyg)*(2.-yyg)/2.
        emul_4 = (1.-yyg)*(-yyg)*(1.+yyg)/6.
        rmul_1 = sx(idel,  jdel-1,n,k,nn)*dmul_2 + sx(idel+1,jdel-1,n,k,nn)*dmul_3
        rmul_2 = sx(idel-1,jdel,  n,k,nn)*cmul_1 + sx(idel,  jdel,  n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel,  n,k,nn)*cmul_3 + sx(idel+2,jdel,  n,k,nn)*cmul_4
        rmul_3 = sx(idel-1,jdel+1,n,k,nn)*cmul_1 + sx(idel,  jdel+1,n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel+1,n,k,nn)*cmul_3 + sx(idel+2,jdel+1,n,k,nn)*cmul_4
        rmul_4 = sx(idel,  jdel+2,n,k,nn)*dmul_2 + sx(idel+1,jdel+2,n,k,nn)*dmul_3
        s(iq,k,nn) = rmul_1*emul_1 + rmul_2*emul_2 + rmul_3*emul_3 + rmul_4*emul_4
      end do     ! iq loop
    end do       ! k loop
  end do         ! nn loop
  !$acc end parallel loop
  !$acc update self(s)
       
!========================   end of intsch=1 section ====================
else     ! if(intsch==1)then
!======================== start of intsch=2 section ====================

  sx(1:ipan,1:jpan,1:npan,1:wlev,1:3) = reshape( s(1:ipan*jpan*npan,1:wlev,1:3), (/ ipan, jpan, npan, wlev, 3 /) )
  do nn = 1,3
    do k = 1,wlev
      do n = 1,npan
        do j = 1,jpan
          iq = 1+(j-1)*ipan+(n-1)*ipan*jpan
          sx(0,j,n,k,nn)      = s( iw(iq),k,nn)
          sx(-1,j,n,k,nn)     = s(iww(iq),k,nn)
          iq = j*ipan+(n-1)*ipan*jpan
          sx(ipan+1,j,n,k,nn) = s( ie(iq),k,nn)
          sx(ipan+2,j,n,k,nn) = s(iee(iq),k,nn)
        end do            ! j loop
        do i = 1,ipan
          iq = i+(n-1)*ipan*jpan
          sx(i,0,n,k,nn)      = s( is(iq),k,nn)
          sx(i,-1,n,k,nn)     = s(iss(iq),k,nn)
          iq = i-ipan+n*ipan*jpan
          sx(i,jpan+1,n,k,nn) = s( in(iq),k,nn)
          sx(i,jpan+2,n,k,nn) = s(inn(iq),k,nn)
        end do            ! i loop
      end do
      do n = 1,npan
        sx(-1,0,n,k,nn)          = s(lsww(n),k,nn)
        sx(0,0,n,k,nn)           = s(isw(1+(n-1)*ipan*jpan),k,nn)
        sx(0,-1,n,k,nn)          = s(lssw(n),k,nn)
        sx(ipan+2,0,n,k,nn)      = s(lsee(n),k,nn)
        sx(ipan+1,-1,n,k,nn)     = s(lsse(n),k,nn)
        sx(-1,jpan+1,n,k,nn)     = s(lnww(n),k,nn)
        sx(0,jpan+1,n,k,nn)      = s(inw(1-ipan+n*ipan*jpan),k,nn)
        sx(0,jpan+2,n,k,nn)      = s(lnnw(n),k,nn)
        sx(ipan+2,jpan+1,n,k,nn) = s(lnee(n),k,nn)
        sx(ipan+1,jpan+2,n,k,nn) = s(lnne(n),k,nn)
        sx(ipan+1,0,n,k,nn)      = s(ise(ipan+(n-1)*ipan*jpan),k,nn)
        sx(ipan+1,jpan+1,n,k,nn) = s(ine(n*ipan*jpan),         k,nn)
      end do           ! n loop
    end do             ! k loop
  end do               ! nn loop

  !$acc update device(sx)

! For other processes
  do ii = neighnum,1,-1
    do nn = 1,3
      do iq = 1,drlen(ii)
        n = nint(dpoints(ii)%a(1,iq)) + noff ! Local index
        idel = int(dpoints(ii)%a(2,iq))
        xxg = dpoints(ii)%a(2,iq) - real(idel)
        jdel = int(dpoints(ii)%a(3,iq))
        yyg = dpoints(ii)%a(3,iq) - real(jdel)
        k = nint(dpoints(ii)%a(4,iq))
        idel = idel - ioff
        jdel = jdel - joff
        ! bi-cubic interpolation
        cmul_1 = (1.-yyg)*(2.-yyg)*(-yyg)/6.
        cmul_2 = (1.-yyg)*(2.-yyg)*(1.+yyg)/2.
        cmul_3 = yyg*(1.+yyg)*(2.-yyg)/2.
        cmul_4 = (1.-yyg)*(-yyg)*(1.+yyg)/6.
        dmul_2 = (1.-yyg)
        dmul_3 = yyg
        emul_1 = (1.-xxg)*(2.-xxg)*(-xxg)/6.
        emul_2 = (1.-xxg)*(2.-xxg)*(1.+xxg)/2.
        emul_3 = xxg*(1.+xxg)*(2.-xxg)/2.
        emul_4 = (1.-xxg)*(-xxg)*(1.+xxg)/6.
        rmul_1 = sx(idel-1,jdel,  n,k,nn)*dmul_2 + sx(idel-1,jdel+1,n,k,nn)*dmul_3
        rmul_2 = sx(idel,  jdel-1,n,k,nn)*cmul_1 + sx(idel,  jdel,  n,k,nn)*cmul_2 + &
                 sx(idel,  jdel+1,n,k,nn)*cmul_3 + sx(idel,  jdel+2,n,k,nn)*cmul_4
        rmul_3 = sx(idel+1,jdel-1,n,k,nn)*cmul_1 + sx(idel+1,jdel,  n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel+1,n,k,nn)*cmul_3 + sx(idel+1,jdel+2,n,k,nn)*cmul_4
        rmul_4 = sx(idel+2,jdel,  n,k,nn)*dmul_2 + sx(idel+2,jdel+1,n,k,nn)*dmul_3
        sextra(ii)%a(iq+(nn-1)*drlen(ii)) = rmul_1*emul_1 + rmul_2*emul_2 + rmul_3*emul_3 + rmul_4*emul_4
      end do          ! iq loop
    end do            ! nn loop
  end do              ! ii loop

  call intssync_send(3)

  !$acc parallel loop collapse(3) present(xg,yg,nface,sx,s)
  do concurrent (nn = 1:3)
    do concurrent (k = 1:wlev)
      do concurrent (iq = 1:ifull)
        idel = int(xg(iq,k))
        xxg = xg(iq,k) - real(idel)
        jdel = int(yg(iq,k))
        yyg = yg(iq,k) - real(jdel)
        idel = min( max( idel - ioff, 0), ipan )
        jdel = min( max( jdel - joff, 0), jpan )
        n = min( max( nface(iq,k) + noff, 1), npan )
        ! bi-cubic interpolation
        cmul_1 = (1.-yyg)*(2.-yyg)*(-yyg)/6.
        cmul_2 = (1.-yyg)*(2.-yyg)*(1.+yyg)/2.
        cmul_3 = yyg*(1.+yyg)*(2.-yyg)/2.
        cmul_4 = (1.-yyg)*(-yyg)*(1.+yyg)/6.
        dmul_2 = (1.-yyg)
        dmul_3 = yyg
        emul_1 = (1.-xxg)*(2.-xxg)*(-xxg)/6.
        emul_2 = (1.-xxg)*(2.-xxg)*(1.+xxg)/2.
        emul_3 = xxg*(1.+xxg)*(2.-xxg)/2.
        emul_4 = (1.-xxg)*(-xxg)*(1.+xxg)/6.
        rmul_1 = sx(idel-1,jdel,  n,k,nn)*dmul_2 + sx(idel-1,jdel+1,n,k,nn)*dmul_3
        rmul_2 = sx(idel,  jdel-1,n,k,nn)*cmul_1 + sx(idel,  jdel,  n,k,nn)*cmul_2 + &
                 sx(idel,  jdel+1,n,k,nn)*cmul_3 + sx(idel,  jdel+2,n,k,nn)*cmul_4
        rmul_3 = sx(idel+1,jdel-1,n,k,nn)*cmul_1 + sx(idel+1,jdel,  n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel+1,n,k,nn)*cmul_3 + sx(idel+1,jdel+2,n,k,nn)*cmul_4
        rmul_4 = sx(idel+2,jdel,  n,k,nn)*dmul_2 + sx(idel+2,jdel+1,n,k,nn)*dmul_3
        s(iq,k,nn) = rmul_1*emul_1 + rmul_2*emul_2 + rmul_3*emul_3 + rmul_4*emul_4
      end do
    end do
  end do
  !$acc end parallel loop
  !$acc update self(s)

end if                     ! (intsch==1) .. else ..
!========================   end of intsch=1 section ====================

call intssync_recv(s)

do k = 1,wlev
  where ( wtr(1:ifull,k) )
    x3d(:,k) = x - 0.5*(uc(:,k)+s(1:ifull,k,1)) ! n+1 guess
    y3d(:,k) = y - 0.5*(vc(:,k)+s(1:ifull,k,2)) ! n+1 guess
    z3d(:,k) = z - 0.5*(wc(:,k)+s(1:ifull,k,3)) ! n+1 guess
  elsewhere
    x3d(:,k) = x
    y3d(:,k) = y
    z3d(:,k) = z
  end where
end do

call mlotoij5(x3d,y3d,z3d,nface,xg,yg)
!     Share off processor departure points.
call deptsync(nface,xg,yg)
!$acc update device(nface,xg,yg)

!======================== start of intsch=1 section ====================
if ( intsch==1 ) then
 
  ! Loop over points that need to be calculated for other processes
  do ii = neighnum,1,-1
    do nn = 1,3
      do iq = 1,drlen(ii)
        n = nint(dpoints(ii)%a(1,iq)) + noff ! Local index
        idel = int(dpoints(ii)%a(2,iq))
        xxg = dpoints(ii)%a(2,iq) - real(idel)
        jdel = int(dpoints(ii)%a(3,iq))
        yyg = dpoints(ii)%a(3,iq) - real(jdel)
        k = nint(dpoints(ii)%a(4,iq))
        idel = idel - ioff
        jdel = jdel - joff
        cmul_1 = (1.-xxg)*(2.-xxg)*(-xxg)/6.
        cmul_2 = (1.-xxg)*(2.-xxg)*(1.+xxg)/2.
        cmul_3 = xxg*(1.+xxg)*(2.-xxg)/2.
        cmul_4 = (1.-xxg)*(-xxg)*(1.+xxg)/6.
        dmul_2 = (1.-xxg)
        dmul_3 = xxg
        emul_1 = (1.-yyg)*(2.-yyg)*(-yyg)/6.
        emul_2 = (1.-yyg)*(2.-yyg)*(1.+yyg)/2.
        emul_3 = yyg*(1.+yyg)*(2.-yyg)/2.
        emul_4 = (1.-yyg)*(-yyg)*(1.+yyg)/6.
        rmul_1 = sx(idel,  jdel-1,n,k,nn)*dmul_2 + sx(idel+1,jdel-1,n,k,nn)*dmul_3
        rmul_2 = sx(idel-1,jdel,  n,k,nn)*cmul_1 + sx(idel,  jdel,  n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel,  n,k,nn)*cmul_3 + sx(idel+2,jdel,  n,k,nn)*cmul_4
        rmul_3 = sx(idel-1,jdel+1,n,k,nn)*cmul_1 + sx(idel,  jdel+1,n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel+1,n,k,nn)*cmul_3 + sx(idel+2,jdel+1,n,k,nn)*cmul_4
        rmul_4 = sx(idel,  jdel+2,n,k,nn)*dmul_2 + sx(idel+1,jdel+2,n,k,nn)*dmul_3
        sextra(ii)%a(iq+(nn-1)*drlen(ii)) = rmul_1*emul_1 + rmul_2*emul_2 + rmul_3*emul_3 + rmul_4*emul_4
      end do          ! iq loop
    end do            ! nn loop
  end do              ! ii loop
  
  call intssync_send(3)

  !$acc parallel loop collapse(3) present(xg,yg,nface,sx,s)
  do concurrent (nn = 1:3)
    do concurrent (k = 1:wlev)
      do concurrent (iq = 1:ifull)
        idel = int(xg(iq,k))
        xxg  = xg(iq,k) - real(idel)
        jdel = int(yg(iq,k))
        yyg  = yg(iq,k) - real(jdel)
        idel = min( max( idel - ioff, 0), ipan )
        jdel = min( max( jdel - joff, 0), jpan )
        n = min( max( nface(iq,k) + noff, 1), npan )
        cmul_1 = (1.-xxg)*(2.-xxg)*(-xxg)/6.
        cmul_2 = (1.-xxg)*(2.-xxg)*(1.+xxg)/2.
        cmul_3 = xxg*(1.+xxg)*(2.-xxg)/2.
        cmul_4 = (1.-xxg)*(-xxg)*(1.+xxg)/6.
        dmul_2 = (1.-xxg)
        dmul_3 = xxg
        emul_1 = (1.-yyg)*(2.-yyg)*(-yyg)/6.
        emul_2 = (1.-yyg)*(2.-yyg)*(1.+yyg)/2.
        emul_3 = yyg*(1.+yyg)*(2.-yyg)/2.
        emul_4 = (1.-yyg)*(-yyg)*(1.+yyg)/6.
        rmul_1 = sx(idel,  jdel-1,n,k,nn)*dmul_2 + sx(idel+1,jdel-1,n,k,nn)*dmul_3
        rmul_2 = sx(idel-1,jdel,  n,k,nn)*cmul_1 + sx(idel,  jdel,  n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel,  n,k,nn)*cmul_3 + sx(idel+2,jdel,  n,k,nn)*cmul_4
        rmul_3 = sx(idel-1,jdel+1,n,k,nn)*cmul_1 + sx(idel,  jdel+1,n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel+1,n,k,nn)*cmul_3 + sx(idel+2,jdel+1,n,k,nn)*cmul_4
        rmul_4 = sx(idel,  jdel+2,n,k,nn)*dmul_2 + sx(idel+1,jdel+2,n,k,nn)*dmul_3
        s(iq,k,nn) = rmul_1*emul_1 + rmul_2*emul_2 + rmul_3*emul_3 + rmul_4*emul_4
      end do     ! iq loop
    end do       ! k loop
  end do         ! nn loop
  !$acc end parallel loop
  !$acc update self(s)
       
!========================   end of intsch=1 section ====================
else     ! if(intsch==1)then
!======================== start of intsch=2 section ====================

  ! For other processes
  do ii = neighnum,1,-1
    do nn = 1,3
      do iq = 1,drlen(ii)
        n = nint(dpoints(ii)%a(1,iq)) + noff ! Local index
        idel = int(dpoints(ii)%a(2,iq))
        xxg = dpoints(ii)%a(2,iq) - real(idel)
        jdel = int(dpoints(ii)%a(3,iq))
        yyg = dpoints(ii)%a(3,iq) - real(jdel)
        k = nint(dpoints(ii)%a(4,iq))
        idel = idel - ioff
        jdel = jdel - joff
        cmul_1 = (1.-yyg)*(2.-yyg)*(-yyg)/6.
        cmul_2 = (1.-yyg)*(2.-yyg)*(1.+yyg)/2.
        cmul_3 = yyg*(1.+yyg)*(2.-yyg)/2.
        cmul_4 = (1.-yyg)*(-yyg)*(1.+yyg)/6.
        dmul_2 = (1.-yyg)
        dmul_3 = yyg
        emul_1 = (1.-xxg)*(2.-xxg)*(-xxg)/6.
        emul_2 = (1.-xxg)*(2.-xxg)*(1.+xxg)/2.
        emul_3 = xxg*(1.+xxg)*(2.-xxg)/2.
        emul_4 = (1.-xxg)*(-xxg)*(1.+xxg)/6.
        rmul_1 = sx(idel-1,jdel,  n,k,nn)*dmul_2 + sx(idel-1,jdel+1,n,k,nn)*dmul_3
        rmul_2 = sx(idel,  jdel-1,n,k,nn)*cmul_1 + sx(idel,  jdel,  n,k,nn)*cmul_2 + &
                 sx(idel,  jdel+1,n,k,nn)*cmul_3 + sx(idel,  jdel+2,n,k,nn)*cmul_4
        rmul_3 = sx(idel+1,jdel-1,n,k,nn)*cmul_1 + sx(idel+1,jdel,  n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel+1,n,k,nn)*cmul_3 + sx(idel+1,jdel+2,n,k,nn)*cmul_4
        rmul_4 = sx(idel+2,jdel,  n,k,nn)*dmul_2 + sx(idel+2,jdel+1,n,k,nn)*dmul_3
        sextra(ii)%a(iq+(nn-1)*drlen(ii)) = rmul_1*emul_1 + rmul_2*emul_2 + rmul_3*emul_3 + rmul_4*emul_4
      end do          ! iq loop
    end do            ! nn loop
  end do              ! ii loop

  call intssync_send(3)

  !$acc parallel loop collapse(3) present(xg,yg,nface,sx,s)
  do concurrent (nn = 1:3)
    do concurrent (k = 1:wlev)
      do concurrent (iq = 1:ifull)
        idel = int(xg(iq,k))
        xxg = xg(iq,k) - real(idel)
        jdel = int(yg(iq,k))
        yyg = yg(iq,k) - real(jdel)
        idel = min( max( idel - ioff, 0), ipan )
        jdel = min( max( jdel - joff, 0), jpan )
        n = min( max( nface(iq,k) + noff, 1), npan )
        ! bi-cubic interpolation
        cmul_1 = (1.-yyg)*(2.-yyg)*(-yyg)/6.
        cmul_2 = (1.-yyg)*(2.-yyg)*(1.+yyg)/2.
        cmul_3 = yyg*(1.+yyg)*(2.-yyg)/2.
        cmul_4 = (1.-yyg)*(-yyg)*(1.+yyg)/6.
        dmul_2 = (1.-yyg)
        dmul_3 = yyg
        emul_1 = (1.-xxg)*(2.-xxg)*(-xxg)/6.
        emul_2 = (1.-xxg)*(2.-xxg)*(1.+xxg)/2.
        emul_3 = xxg*(1.+xxg)*(2.-xxg)/2.
        emul_4 = (1.-xxg)*(-xxg)*(1.+xxg)/6.
        rmul_1 = sx(idel-1,jdel,  n,k,nn)*dmul_2 + sx(idel-1,jdel+1,n,k,nn)*dmul_3
        rmul_2 = sx(idel,  jdel-1,n,k,nn)*cmul_1 + sx(idel,  jdel,  n,k,nn)*cmul_2 + &
                 sx(idel,  jdel+1,n,k,nn)*cmul_3 + sx(idel,  jdel+2,n,k,nn)*cmul_4
        rmul_3 = sx(idel+1,jdel-1,n,k,nn)*cmul_1 + sx(idel+1,jdel,  n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel+1,n,k,nn)*cmul_3 + sx(idel+1,jdel+2,n,k,nn)*cmul_4
        rmul_4 = sx(idel+2,jdel,  n,k,nn)*dmul_2 + sx(idel+2,jdel+1,n,k,nn)*dmul_3
        s(iq,k,nn) = rmul_1*emul_1 + rmul_2*emul_2 + rmul_3*emul_3 + rmul_4*emul_4
      end do
    end do
  end do
  !$acc end parallel loop
  !$acc update self(s)

end if                     ! (intsch==1) .. else ..
!========================   end of intsch=1 section ====================

!$acc end data

call intssync_recv(s)

do k = 1,wlev
  where (wtr(1:ifull,k))
    x3d(:,k) = x - 0.5*(uc(:,k)+s(1:ifull,k,1)) ! n+1 guess
    y3d(:,k) = y - 0.5*(vc(:,k)+s(1:ifull,k,2)) ! n+1 guess
    z3d(:,k) = z - 0.5*(wc(:,k)+s(1:ifull,k,3)) ! n+1 guess
  elsewhere
    x3d(:,k) = x
    y3d(:,k) = y
    z3d(:,k) = z
  end where
end do

call mlotoij5(x3d,y3d,z3d,nface,xg,yg)
!     Share off processor departure points.
call deptsync(nface,xg,yg)

call END_LOG(waterdeps_end)

return
end subroutine mlodeps

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Calculate indices
! This code is from depts.f90

pure subroutine mlotoij5(x3d,y3d,z3d,nface,xg,yg)

use bigxy4_m
use cc_mpi
use mlo
use newmpar_m
use parm_m
use parmgeom_m
use xyzinfo_m

implicit none

integer loop,iq,i,j,is,js
integer ii
integer, dimension(ifull,wlev), intent(out) :: nface
real, dimension(ifull,wlev), intent(out) :: xg,yg
real, dimension(ifull) :: xstr,ystr,zstr
real, dimension(ifull) :: denxyz,xd,yd,zd
real, dimension(ifull) :: ri,rj
real(kind=8), dimension(ifull,wlev), intent(inout) :: x3d,y3d,z3d
real(kind=8), dimension(ifull) :: den
real(kind=8) alf,alfonsch
real(kind=8) dxx,dxy,dyx,dyy
integer, parameter :: nmaploop = 3

alf = (1._8-schmidt*schmidt)/(1._8+schmidt*schmidt)
alfonsch = 2._8*schmidt/(1._8+schmidt*schmidt)

do ii = 1,wlev

  !     if necessary, transform (x3d, y3d, z3d) to equivalent
  !     coordinates (xstr, ystr, zstr) on regular gnomonic panels
  den=1._8-alf*z3d(:,ii) ! to force real*8
  xstr=real(x3d(:,ii)*(alfonsch/den))
  ystr=real(y3d(:,ii)*(alfonsch/den))
  zstr=real((z3d(:,ii)-alf)/den)

!      first deduce departure faces
!      instead calculate cubic coordinates
!      The faces are:
!      0: X=1   1: Z=1   2: Y=1   3: X=-1   4: Z=-1   5: Y=-1
  denxyz=max( abs(xstr),abs(ystr),abs(zstr) )
  xd=xstr/denxyz
  yd=ystr/denxyz
  zd=zstr/denxyz

  where (abs(xstr-denxyz)<1.E-8)
    nface(:,ii)    =0
    xg(:,ii) =      yd
    yg(:,ii) =      zd
  elsewhere (abs(xstr+denxyz)<1.E-8)
    nface(:,ii)    =3
    xg(:,ii) =     -zd
    yg(:,ii) =     -yd
  elsewhere (abs(zstr-denxyz)<1.E-8)
    nface(:,ii)    =1
    xg(:,ii) =      yd
    yg(:,ii) =     -xd
  elsewhere (abs(zstr+denxyz)<1.E-8)
    nface(:,ii)    =4
    xg(:,ii) =      xd
    yg(:,ii) =     -yd
  elsewhere (abs(ystr-denxyz)<1.E-8)
    nface(:,ii)    =2
    xg(:,ii) =     -zd
    yg(:,ii) =     -xd
  elsewhere
    nface(:,ii)    =5
    xg(:,ii) =      xd
    yg(:,ii) =      zd
  end where

  !     use 4* resolution grid il --> 4*il
  xg(:,ii)=min(max(-.999999,xg(:,ii)),.999999)
  yg(:,ii)=min(max(-.999999,yg(:,ii)),.999999)
  !      first guess for ri, rj and nearest i,j
  ri=1.+(1.+xg(:,ii))*real(2*il_g)
  rj=1.+(1.+yg(:,ii))*real(2*il_g)
  do loop=1,nmaploop
    do iq=1,ifull
      i=nint(ri(iq))
      j=nint(rj(iq))
      is=nint(sign(1.,ri(iq)-real(i)))
      js=nint(sign(1.,rj(iq)-real(j)))
      ! predict new value for ri, rj
      dxx=xx4(i+is,j)-xx4(i,j)
      dyx=xx4(i,j+js)-xx4(i,j)
      dxy=yy4(i+is,j)-yy4(i,j)
      dyy=yy4(i,j+js)-yy4(i,j)       
      den(iq)=dxx*dyy-dyx*dxy
      ri(iq) = real(i) + real(is)*real(((xg(iq,ii)-xx4(i,j))*dyy-(yg(iq,ii)-yy4(i,j))*dyx)/den(iq))
      rj(iq) = real(j) + real(js)*real(((yg(iq,ii)-yy4(i,j))*dxx-(xg(iq,ii)-xx4(i,j))*dxy)/den(iq))
    end do
    ri(1:ifull) = min(ri(1:ifull),1.0+1.999999*real(2*il_g))
    ri(1:ifull) = max(ri(1:ifull),1.0+0.000001*real(2*il_g))
    rj(1:ifull) = min(rj(1:ifull),1.0+1.999999*real(2*il_g))
    rj(1:ifull) = max(rj(1:ifull),1.0+0.000001*real(2*il_g))
  end do  ! loop loop
  !      expect xg, yg to range between .5 and il+.5
  xg(:,ii)=0.25*(ri+3.)-0.5  ! -.5 for stag; back to normal ri, rj defn
  yg(:,ii)=0.25*(rj+3.)-0.5  ! -.5 for stag

end do

return
end subroutine mlotoij5

subroutine mlob2ints_bs(s,nface,xg,yg,wtr)

use cc_mpi
use indices_m
use mlo
use newmpar_m
use parm_m
use parmhor_m

implicit none

integer idel,iq,jdel
integer i,j,k,n,intsch
integer ii,ntr,nn
integer, dimension(ifull,wlev), intent(in) :: nface
integer s_count
real, dimension(ifull,wlev), intent(in) :: xg,yg
real, dimension(:,:,:), intent(inout) :: s
real, dimension(-1:ipan+2,-1:jpan+2,1:npan,wlev,size(s,3)) :: sx
real, dimension(ifull+iextra,wlev,size(s,3)) :: s_old
real, dimension(ifull,wlev,size(s,3)) :: s_store
real s_tot, s_test
real cmax, cmin, xxg, yyg
real dmul_2, dmul_3, cmul_1, cmul_2, cmul_3, cmul_4
real emul_1, emul_2, emul_3, emul_4, rmul_1, rmul_2, rmul_3, rmul_4
real, parameter :: cxx = -9999. ! missing value flag
logical, dimension(ifull+iextra,wlev), intent(in) :: wtr

call START_LOG(waterints_begin)

ntr = size(s,3)
intsch = mod(ktau,2)

do nn = 1,ntr
  do k = 1,wlev
    s_store(1:ifull,k,nn) = s(1:ifull,k,nn)
    where (.not.wtr(1:ifull,k))
      s(1:ifull,k,nn) = cxx - 1. ! missing value flag
    end where
  end do
end do

! fill
do ii = 1,3 ! 3 iterations of fill should be enough
  s_old(1:ifull,:,:) = s(1:ifull,:,:)
  call bounds(s_old)
  do concurrent (nn = 1:ntr)
    do concurrent (k = 1:wlev)
      do concurrent (iq = 1:ifull)
        if ( s(iq,k,nn)<cxx ) then
          s_tot = 0.
          s_count = 0
          s_test = s_old(is(iq),k,nn)
          if ( s_test>cxx ) then
            s_tot = s_tot + s_test
            s_count = s_count +1
          end if
          s_test = s_old(in(iq),k,nn)
          if ( s_test>cxx ) then
            s_tot = s_tot + s_test
            s_count = s_count +1
          end if 
          s_test = s_old(ie(iq),k,nn)
          if ( s_test>cxx ) then
            s_tot = s_tot + s_test
            s_count = s_count +1
          end if
          s_test = s_old(iw(iq),k,nn)
          if ( s_test>cxx ) then
            s_tot = s_tot + s_test
            s_count = s_count +1
          end if
          if ( s_count>0 ) then
            s(iq,k,nn) = s_tot/real(s_count)
          end if
        end if
      end do
    end do
  end do
end do

call bounds(s,nrows=2)

!======================== start of intsch=1 section ====================
if ( intsch==1 ) then

  sx(1:ipan,1:jpan,1:npan,1:wlev,1:ntr) = reshape( s(1:ipan*jpan*npan,1:wlev,1:ntr), (/ ipan, jpan, npan, wlev, ntr /) )
  do nn = 1,ntr
    do k = 1,wlev
      do n = 1,npan
        do j = 1,jpan
          iq = 1+(j-1)*ipan+(n-1)*ipan*jpan
          sx(0,j,n,k,nn)      = s( iw(iq),k,nn)
          sx(-1,j,n,k,nn)     = s(iww(iq),k,nn)
          iq = j*ipan+(n-1)*ipan*jpan
          sx(ipan+1,j,n,k,nn) = s( ie(iq),k,nn)
          sx(ipan+2,j,n,k,nn) = s(iee(iq),k,nn)
        end do            ! j loop
        do i = 1,ipan
          iq = i+(n-1)*ipan*jpan
          sx(i,0,n,k,nn)      = s( is(iq),k,nn)
          sx(i,-1,n,k,nn)     = s(iss(iq),k,nn)
          iq = i-ipan+n*ipan*jpan
          sx(i,jpan+1,n,k,nn) = s( in(iq),k,nn)
          sx(i,jpan+2,n,k,nn) = s(inn(iq),k,nn)
        end do            ! i loop
      end do
!   for ew interpolation, sometimes need (different from ns):
!       (-1,0),   (0,0),   (0,-1)   (-1,il+1),   (0,il+1),   (0,il+2)
!     (il+1,0),(il+2,0),(il+1,-1) (il+1,il+1),(il+2,il+1),(il+1,il+2)
      do n = 1,npan
        sx(-1,0,n,k,nn)          = s(lwws(n),                  k,nn)
        sx(0,0,n,k,nn)           = s(iws(1+(n-1)*ipan*jpan),   k,nn)
        sx(0,-1,n,k,nn)          = s(lwss(n),                  k,nn)
        sx(ipan+1,0,n,k,nn)      = s(ies(ipan+(n-1)*ipan*jpan),k,nn)
        sx(ipan+2,0,n,k,nn)      = s(lees(n),                  k,nn)
        sx(ipan+1,-1,n,k,nn)     = s(less(n),                  k,nn)
        sx(-1,jpan+1,n,k,nn)     = s(lwwn(n),                  k,nn)
        sx(0,jpan+2,n,k,nn)      = s(lwnn(n),                  k,nn)
        sx(ipan+2,jpan+1,n,k,nn) = s(leen(n),                  k,nn)
        sx(ipan+1,jpan+2,n,k,nn) = s(lenn(n),                  k,nn)
        sx(0,jpan+1,n,k,nn)      = s(iwn(1-ipan+n*ipan*jpan),  k,nn)
        sx(ipan+1,jpan+1,n,k,nn) = s(ien(n*ipan*jpan),         k,nn)
      end do           ! n loop
    end do             ! k loop
  end do               ! nn loop

! Loop over points that need to be calculated for other processes
  do ii=neighnum,1,-1
    do nn = 1,ntr
      do iq=1,drlen(ii)
        n = nint(dpoints(ii)%a(1,iq)) + noff ! Local index
        idel = int(dpoints(ii)%a(2,iq))
        xxg = dpoints(ii)%a(2,iq) - real(idel)
        jdel = int(dpoints(ii)%a(3,iq))
        yyg = dpoints(ii)%a(3,iq) - real(jdel)
        k = nint(dpoints(ii)%a(4,iq))
        idel = idel - ioff
        jdel = jdel - joff
        ! bi-cubic interpolation
        cmul_1 = (1.-xxg)*(2.-xxg)*(-xxg)/6.
        cmul_2 = (1.-xxg)*(2.-xxg)*(1.+xxg)/2.
        cmul_3 = xxg*(1.+xxg)*(2.-xxg)/2.
        cmul_4 = (1.-xxg)*(-xxg)*(1.+xxg)/6.
        dmul_2 = (1.-xxg)
        dmul_3 = xxg
        emul_1 = (1.-yyg)*(2.-yyg)*(-yyg)/6.
        emul_2 = (1.-yyg)*(2.-yyg)*(1.+yyg)/2.
        emul_3 = yyg*(1.+yyg)*(2.-yyg)/2.
        emul_4 = (1.-yyg)*(-yyg)*(1.+yyg)/6.
        cmin = min(sx(idel,  jdel,n,k,nn),sx(idel+1,jdel,  n,k,nn), &
                   sx(idel,jdel+1,n,k,nn),sx(idel+1,jdel+1,n,k,nn))
        cmax = max(sx(idel,  jdel,n,k,nn),sx(idel+1,jdel,  n,k,nn), &
                   sx(idel,jdel+1,n,k,nn),sx(idel+1,jdel+1,n,k,nn))
        rmul_1 = sx(idel,  jdel-1,n,k,nn)*dmul_2 + sx(idel+1,jdel-1,n,k,nn)*dmul_3
        rmul_2 = sx(idel-1,jdel,  n,k,nn)*cmul_1 + sx(idel,  jdel,  n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel,  n,k,nn)*cmul_3 + sx(idel+2,jdel,  n,k,nn)*cmul_4
        rmul_3 = sx(idel-1,jdel+1,n,k,nn)*cmul_1 + sx(idel,  jdel+1,n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel+1,n,k,nn)*cmul_3 + sx(idel+2,jdel+1,n,k,nn)*cmul_4
        rmul_4 = sx(idel,  jdel+2,n,k,nn)*dmul_2 + sx(idel+1,jdel+2,n,k,nn)*dmul_3
        sextra(ii)%a(iq+(nn-1)*drlen(ii)) = min( max( cmin, &
            rmul_1*emul_1 + rmul_2*emul_2 + rmul_3*emul_3 + rmul_4*emul_4 ), cmax ) ! Bermejo & Staniforth
      end do          ! iq loop
    end do            ! nn loop
  end do              ! ii loop

  call intssync_send(ntr)

  !$acc parallel loop collapse(3) copyin(xg,yg,nface,sx) copyout(s)
  do concurrent (nn = 1:ntr)
    do concurrent (k=1:wlev)      
      do concurrent (iq=1:ifull)
        idel=int(xg(iq,k))
        xxg=xg(iq,k) - real(idel)
        jdel=int(yg(iq,k))
        yyg=yg(iq,k) - real(jdel)
        idel = min( max( idel - ioff, 0), ipan )
        jdel = min( max( jdel - joff, 0), jpan )
        n = min( max( nface(iq,k) + noff, 1), npan )
        ! bi-cubic interpolation
        cmul_1 = (1.-xxg)*(2.-xxg)*(-xxg)/6.
        cmul_2 = (1.-xxg)*(2.-xxg)*(1.+xxg)/2.
        cmul_3 = xxg*(1.+xxg)*(2.-xxg)/2.
        cmul_4 = (1.-xxg)*(-xxg)*(1.+xxg)/6.
        dmul_2 = (1.-xxg)
        dmul_3 = xxg
        emul_1 = (1.-yyg)*(2.-yyg)*(-yyg)/6.
        emul_2 = (1.-yyg)*(2.-yyg)*(1.+yyg)/2.
        emul_3 = yyg*(1.+yyg)*(2.-yyg)/2.
        emul_4 = (1.-yyg)*(-yyg)*(1.+yyg)/6.
        cmin = min(sx(idel,  jdel,n,k,nn),sx(idel+1,jdel,  n,k,nn), &
                   sx(idel,jdel+1,n,k,nn),sx(idel+1,jdel+1,n,k,nn))
        cmax = max(sx(idel,  jdel,n,k,nn),sx(idel+1,jdel,  n,k,nn), &
                   sx(idel,jdel+1,n,k,nn),sx(idel+1,jdel+1,n,k,nn))
        rmul_1 = sx(idel,  jdel-1,n,k,nn)*dmul_2 + sx(idel+1,jdel-1,n,k,nn)*dmul_3
        rmul_2 = sx(idel-1,jdel,  n,k,nn)*cmul_1 + sx(idel,  jdel,  n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel,  n,k,nn)*cmul_3 + sx(idel+2,jdel,  n,k,nn)*cmul_4
        rmul_3 = sx(idel-1,jdel+1,n,k,nn)*cmul_1 + sx(idel,  jdel+1,n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel+1,n,k,nn)*cmul_3 + sx(idel+2,jdel+1,n,k,nn)*cmul_4
        rmul_4 = sx(idel,  jdel+2,n,k,nn)*dmul_2 + sx(idel+1,jdel+2,n,k,nn)*dmul_3
        s(iq,k,nn) = min( max( cmin, &
            rmul_1*emul_1 + rmul_2*emul_2 + rmul_3*emul_3 + rmul_4*emul_4 ), cmax ) ! Bermejo & Staniforth
      end do       ! iq loop
    end do         ! k loop
  end do           ! nn loop
  !$acc end parallel loop
       
!========================   end of intsch=1 section ====================
else     ! if(intsch==1)then
!======================== start of intsch=2 section ====================
!       this is intsc           NS interps done first
!       first extend s arrays into sx - this one -1:il+2 & -1:il+2

  sx(1:ipan,1:jpan,1:npan,1:wlev,1:ntr) = reshape( s(1:ipan*jpan*npan,1:wlev,1:ntr), (/ ipan, jpan, npan, wlev, ntr /) )
  do nn = 1,ntr
    do k = 1,wlev
      do n = 1,npan
        do j = 1,jpan
          iq = 1+(j-1)*ipan+(n-1)*ipan*jpan
          sx(0,j,n,k,nn)      = s( iw(iq),k,nn)
          sx(-1,j,n,k,nn)     = s(iww(iq),k,nn)
          iq = j*ipan+(n-1)*ipan*jpan
          sx(ipan+1,j,n,k,nn) = s( ie(iq),k,nn)
          sx(ipan+2,j,n,k,nn) = s(iee(iq),k,nn)
        end do            ! j loop
        do i=1,ipan
          iq = i+(n-1)*ipan*jpan
          sx(i,0,n,k,nn)      = s( is(iq),k,nn)
          sx(i,-1,n,k,nn)     = s(iss(iq),k,nn)
          iq = i-ipan+n*ipan*jpan
          sx(i,jpan+1,n,k,nn) = s( in(iq),k,nn)
          sx(i,jpan+2,n,k,nn) = s(inn(iq),k,nn)
        end do            ! i loop
      end do
!   for ns interpolation, sometimes need (different from ew):
!        (-1,0),   (0,0),   (0,-1)   (-1,il+1),   (0,il+1),   (0,il+2)
!      (il+1,0),(il+2,0),(il+1,-1) (il+1,il+1),(il+2,il+1),(il+1,il+2)
      do n = 1,npan
        sx(-1,0,n,k,nn)          = s(lsww(n),k,nn)
        sx(0,0,n,k,nn)           = s(isw(1+(n-1)*ipan*jpan),   k,nn)
        sx(0,-1,n,k,nn)          = s(lssw(n),k,nn)
        sx(ipan+2,0,n,k,nn)      = s(lsee(n),k,nn)
        sx(ipan+1,-1,n,k,nn)     = s(lsse(n),k,nn)
        sx(-1,jpan+1,n,k,nn)     = s(lnww(n),k,nn)
        sx(0,jpan+1,n,k,nn)      = s(inw(1-ipan+n*ipan*jpan),  k,nn)
        sx(0,jpan+2,n,k,nn)      = s(lnnw(n),k,nn)
        sx(ipan+2,jpan+1,n,k,nn) = s(lnee(n),k,nn)
        sx(ipan+1,jpan+2,n,k,nn) = s(lnne(n),k,nn)
        sx(ipan+1,0,n,k,nn)      = s(ise(ipan+(n-1)*ipan*jpan),k,nn)
        sx(ipan+1,jpan+1,n,k,nn) = s(ine(n*ipan*jpan),         k,nn)
      end do           ! n loop
    end do             ! k loop
  end do               ! nn loop

! For other processes
  do ii=neighnum,1,-1
    do nn = 1,ntr
      do iq=1,drlen(ii)
        n = nint(dpoints(ii)%a(1,iq)) + noff ! Local index
        !  Need global face index in fproc call
        idel = int(dpoints(ii)%a(2,iq))
        xxg = dpoints(ii)%a(2,iq) - real(idel)
        jdel = int(dpoints(ii)%a(3,iq))
        yyg = dpoints(ii)%a(3,iq) - real(jdel)
        k = nint(dpoints(ii)%a(4,iq))
        idel = idel - ioff
        jdel = jdel - joff
        ! bi-cubic interpolation
        cmul_1 = (1.-yyg)*(2.-yyg)*(-yyg)/6.
        cmul_2 = (1.-yyg)*(2.-yyg)*(1.+yyg)/2.
        cmul_3 = yyg*(1.+yyg)*(2.-yyg)/2.
        cmul_4 = (1.-yyg)*(-yyg)*(1.+yyg)/6.
        dmul_2 = (1.-yyg)
        dmul_3 = yyg
        emul_1 = (1.-xxg)*(2.-xxg)*(-xxg)/6.
        emul_2 = (1.-xxg)*(2.-xxg)*(1.+xxg)/2.
        emul_3 = xxg*(1.+xxg)*(2.-xxg)/2.
        emul_4 = (1.-xxg)*(-xxg)*(1.+xxg)/6.
        cmin = min(sx(idel,  jdel,n,k,nn),sx(idel+1,jdel,  n,k,nn), &
                   sx(idel,jdel+1,n,k,nn),sx(idel+1,jdel+1,n,k,nn))
        cmax = max(sx(idel,  jdel,n,k,nn),sx(idel+1,jdel,  n,k,nn), &
                   sx(idel,jdel+1,n,k,nn),sx(idel+1,jdel+1,n,k,nn))
        rmul_1 = sx(idel-1,jdel,  n,k,nn)*dmul_2 + sx(idel-1,jdel+1,n,k,nn)*dmul_3
        rmul_2 = sx(idel,  jdel-1,n,k,nn)*cmul_1 + sx(idel,  jdel,  n,k,nn)*cmul_2 + &
                 sx(idel,  jdel+1,n,k,nn)*cmul_3 + sx(idel,  jdel+2,n,k,nn)*cmul_4
        rmul_3 = sx(idel+1,jdel-1,n,k,nn)*cmul_1 + sx(idel+1,jdel,  n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel+1,n,k,nn)*cmul_3 + sx(idel+1,jdel+2,n,k,nn)*cmul_4
        rmul_4 = sx(idel+2,jdel,  n,k,nn)*dmul_2 + sx(idel+2,jdel+1,n,k,nn)*dmul_3
        sextra(ii)%a(iq+(nn-1)*drlen(ii)) = min( max( cmin, &
            rmul_1*emul_1 + rmul_2*emul_2 + rmul_3*emul_3 + rmul_4*emul_4 ), cmax ) ! Bermejo & Staniforth
      end do          ! iq loop
    end do            ! nn loop
  end do              ! ii loop

  call intssync_send(ntr)

  !$acc parallel loop collapse(3) copyin(xg,yg,nface,sx,s)
  do concurrent (nn = 1:ntr)
    do concurrent (k = 1:wlev)
      do concurrent (iq = 1:ifull)
        idel=int(xg(iq,k))
        xxg=xg(iq,k)-real(idel)
        jdel=int(yg(iq,k))
        yyg=yg(iq,k)-real(jdel)
        idel = min( max( idel - ioff, 0), ipan )
        jdel = min( max( jdel - joff, 0), jpan )
        n = min( max( nface(iq,k) + noff, 1), npan )
        ! bi-cubic interpolation
        cmul_1 = (1.-yyg)*(2.-yyg)*(-yyg)/6.
        cmul_2 = (1.-yyg)*(2.-yyg)*(1.+yyg)/2.
        cmul_3 = yyg*(1.+yyg)*(2.-yyg)/2.
        cmul_4 = (1.-yyg)*(-yyg)*(1.+yyg)/6.
        dmul_2 = (1.-yyg)
        dmul_3 = yyg
        emul_1 = (1.-xxg)*(2.-xxg)*(-xxg)/6.
        emul_2 = (1.-xxg)*(2.-xxg)*(1.+xxg)/2.
        emul_3 = xxg*(1.+xxg)*(2.-xxg)/2.
        emul_4 = (1.-xxg)*(-xxg)*(1.+xxg)/6.
        cmin = min(sx(idel,  jdel,n,k,nn),sx(idel+1,jdel,  n,k,nn), &
                   sx(idel,jdel+1,n,k,nn),sx(idel+1,jdel+1,n,k,nn))
        cmax = max(sx(idel,  jdel,n,k,nn),sx(idel+1,jdel,  n,k,nn), &
                   sx(idel,jdel+1,n,k,nn),sx(idel+1,jdel+1,n,k,nn))
        rmul_1 = sx(idel-1,jdel,  n,k,nn)*dmul_2 + sx(idel-1,jdel+1,n,k,nn)*dmul_3
        rmul_2 = sx(idel,  jdel-1,n,k,nn)*cmul_1 + sx(idel,  jdel,  n,k,nn)*cmul_2 + &
                 sx(idel,  jdel+1,n,k,nn)*cmul_3 + sx(idel,  jdel+2,n,k,nn)*cmul_4
        rmul_3 = sx(idel+1,jdel-1,n,k,nn)*cmul_1 + sx(idel+1,jdel,  n,k,nn)*cmul_2 + &
                 sx(idel+1,jdel+1,n,k,nn)*cmul_3 + sx(idel+1,jdel+2,n,k,nn)*cmul_4
        rmul_4 = sx(idel+2,jdel,  n,k,nn)*dmul_2 + sx(idel+2,jdel+1,n,k,nn)*dmul_3
        s(iq,k,nn) = min( max( cmin, &
            rmul_1*emul_1 + rmul_2*emul_2 + rmul_3*emul_3 + rmul_4*emul_4 ), cmax ) ! Bermejo & Staniforth
      end do
    end do
  end do
  !$acc end parallel loop

end if                     ! (intsch==1) .. else ..
!========================   end of intsch=1 section ====================

call intssync_recv(s)

do nn = 1,ntr
  do k = 1,wlev
    where ( .not.wtr(1:ifull,k) .or. s(1:ifull,k,nn)<cxx+10. )
      s(1:ifull,k,nn) = s_store(1:ifull,k,nn)
    end where
  end do
end do

call END_LOG(waterints_end)

return
end subroutine mlob2ints_bs


!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Rotate wind vector to arrival point

pure subroutine mlorot(cou,cov,cow,x3d,y3d,z3d)

use mlo
use xyzinfo_m
use newmpar_m

implicit none

integer k
real, dimension(ifull+iextra,wlev), intent(inout) :: cou,cov,cow
real, dimension(ifull) :: vec1x,vec1y,vec1z,denb
real, dimension(ifull) :: vec2x,vec2y,vec2z,vecdot
real, dimension(ifull) :: vec3x,vec3y,vec3z,vdot1,vdot2
real(kind=8), dimension(ifull,size(cou,2)), intent(in) :: x3d,y3d,z3d

do k = 1,wlev
!         cross product n1xn2 into vec1
  vec1x = real(y3d(:,k)*z - y*z3d(:,k))
  vec1y = real(z3d(:,k)*x - z*x3d(:,k))
  vec1z = real(x3d(:,k)*y - x*y3d(:,k))
  denb = vec1x*vec1x + vec1y*vec1y + vec1z*vec1z
!         N.B. rotation formula is singular for small denb,
!         but the rotation is unnecessary in this case
  where ( denb>1.e-10 )
    vecdot = real(x3d(:,k)*x + y3d(:,k)*y + z3d(:,k)*z)
    vec2x = real(x3d(:,k)*vecdot - x)
    vec2y = real(y3d(:,k)*vecdot - y)
    vec2z = real(z3d(:,k)*vecdot - z)
    vec3x = real(x3d(:,k) - vecdot*x)
    vec3y = real(y3d(:,k) - vecdot*y)
    vec3z = real(z3d(:,k) - vecdot*z)
    vdot1 = (vec1x*cou(1:ifull,k) + vec1y*cov(1:ifull,k) + vec1z*cow(1:ifull,k))/denb
    vdot2 = (vec2x*cou(1:ifull,k) + vec2y*cov(1:ifull,k) + vec2z*cow(1:ifull,k))/denb
    cou(1:ifull,k) = vdot1*vec1x + vdot2*vec3x
    cov(1:ifull,k) = vdot1*vec1y + vdot2*vec3y
    cow(1:ifull,k) = vdot1*vec1z + vdot2*vec3z
  end where
end do ! k

return
end subroutine mlorot

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Stagger u and v
! Modified to include zero velocity next to land points
subroutine mlostaguv(u,v,uout,vout)

use cc_mpi
use indices_m
use mlo
use newmpar_m
use parm_m

implicit none

integer i,k,itn,kx,kn,iq
real, dimension(:,:), intent(in) :: u, v
real, dimension(:,:), intent(out) :: uout,vout
real, dimension(ifull+iextra,size(u,2)) :: uin,vin
real, dimension(ifull+iextra,size(u,2)) :: ua,va
real, dimension(ifull+iextra,size(u,2)) :: ud,vd
real, dimension(:,:,:), allocatable, save :: wtul,wtvl
real, dimension(:,:,:), allocatable, save :: wtur,wtvr
real, dimension(:,:,:), allocatable, save :: dtul,dtvl
real, dimension(:,:,:), allocatable, save :: dtur,dtvr
real, dimension(ifull,0:3) :: nwtu,nwtv
real, dimension(:,:), allocatable, save :: stul,stvl
real, dimension(:,:), allocatable, save :: stur,stvr
logical, dimension(ifull) :: euetest,euwtest,evntest,evstest
logical, dimension(ifull) :: euewtest,evnstest,eutest,evtest
logical ltest

call START_LOG(ocnstag_begin)

if (.not.allocated(wtul)) then
  allocate(wtul(ifull+iextra,wlev,0:3),wtvl(ifull+iextra,wlev,0:3))
  allocate(wtur(ifull+iextra,wlev,0:3),wtvr(ifull+iextra,wlev,0:3))
  allocate(dtul(ifull,wlev,3),dtvl(ifull,wlev,3))
  allocate(dtur(ifull,wlev,3),dtvr(ifull,wlev,3))
  allocate(stul(ifull,wlev),stvl(ifull,wlev))
  allocate(stur(ifull,wlev),stvr(ifull,wlev))
  
  ! assign land arrays
  do k = 1,wlev
    eutest = ee(1:ifull,k)*ee(ie,k)>0.5
    evtest = ee(1:ifull,k)*ee(in,k)>0.5
    euetest = eutest     .and. ee(ie,k)*ee(iee,k)>0.5
    euwtest = ee(iw,k)*ee(1:ifull,k)>0.5 .and. eutest
    evntest = evtest     .and. ee(in,k)*ee(inn,k)>0.5
    evstest = ee(is,k)*ee(1:ifull,k)>0.5 .and. evtest
    euewtest = euetest .and. euwtest
    evnstest = evntest .and. evstest

    ! assign weights (left)

    ! |   *   | X E   |  EE  |     unstaggered
    ! W       * X     E            staggered
    where (euewtest)
      wtul(1:ifull,k,0)=1.
      wtul(1:ifull,k,1)=-0.5
      wtul(1:ifull,k,2)=-0.1
      wtul(1:ifull,k,3)=0.
      dtul(1:ifull,k,1)=0.1
      dtul(1:ifull,k,2)=1.
      dtul(1:ifull,k,3)=0.5

    ! #   *   | X E   |  EE  |     unstaggered
    ! 0       * X     E            staggered
    elsewhere (euetest)
      wtul(1:ifull,k,0)=1.
      wtul(1:ifull,k,1)=-0.5
      wtul(1:ifull,k,2)=0.
      wtul(1:ifull,k,3)=0.
      dtul(1:ifull,k,1)=0.1
      dtul(1:ifull,k,2)=1.
      dtul(1:ifull,k,3)=0.5

    ! |   *   | X E   #  ##  #     unstaggered
    !         * X     0  ##  #     staggered
    elsewhere (euwtest)
      wtul(1:ifull,k,0)=1.
      wtul(1:ifull,k,1)=0.
      wtul(1:ifull,k,2)=0.
      wtul(1:ifull,k,3)=0.
      dtul(1:ifull,k,1)=0.
      dtul(1:ifull,k,2)=1.
      dtul(1:ifull,k,3)=1./3.

    ! #   *   |   E   #  ##  #     unstaggered
    ! #       *       #  ##  #     staggered
    elsewhere (eutest)
      wtul(1:ifull,k,0)=1.
      wtul(1:ifull,k,1)=0.
      wtul(1:ifull,k,2)=0.
      wtul(1:ifull,k,3)=0.
      dtul(1:ifull,k,1)=0.
      dtul(1:ifull,k,2)=0.5
      dtul(1:ifull,k,3)=0.5

    elsewhere
      wtul(1:ifull,k,0)=0.
      wtul(1:ifull,k,1)=0.
      wtul(1:ifull,k,2)=0.
      wtul(1:ifull,k,3)=0.
      dtul(1:ifull,k,1)=0.
      dtul(1:ifull,k,2)=0.
      dtul(1:ifull,k,3)=0.
            
    end where
    where (evnstest)
      wtvl(1:ifull,k,0)=1.
      wtvl(1:ifull,k,1)=-0.5
      wtvl(1:ifull,k,2)=-0.1
      wtvl(1:ifull,k,3)=0.
      dtvl(1:ifull,k,1)=0.1
      dtvl(1:ifull,k,2)=1.
      dtvl(1:ifull,k,3)=0.5
    elsewhere (evntest)
      wtvl(1:ifull,k,0)=1.
      wtvl(1:ifull,k,1)=-0.5
      wtvl(1:ifull,k,2)=0.
      wtvl(1:ifull,k,3)=0.
      dtvl(1:ifull,k,1)=0.1
      dtvl(1:ifull,k,2)=1.
      dtvl(1:ifull,k,3)=0.5
    elsewhere (evstest)
      wtvl(1:ifull,k,0)=1.
      wtvl(1:ifull,k,1)=0.
      wtvl(1:ifull,k,2)=0.
      wtvl(1:ifull,k,3)=0.
      dtvl(1:ifull,k,1)=0. 
      dtvl(1:ifull,k,2)=1.
      dtvl(1:ifull,k,3)=1./3.
    elsewhere (evtest)
      wtvl(1:ifull,k,0)=1.
      wtvl(1:ifull,k,1)=0.
      wtvl(1:ifull,k,2)=0.
      wtvl(1:ifull,k,3)=0.
      dtvl(1:ifull,k,1)=0.
      dtvl(1:ifull,k,2)=0.5
      dtvl(1:ifull,k,3)=0.5
    elsewhere
      wtvl(1:ifull,k,0)=0.
      wtvl(1:ifull,k,1)=0.
      wtvl(1:ifull,k,2)=0.
      wtvl(1:ifull,k,3)=0.
      dtvl(1:ifull,k,1)=0.
      dtvl(1:ifull,k,2)=0.
      dtvl(1:ifull,k,3)=0.
    end where
  end do
    
  ! Apply JLM's preconditioner
  do i = 0,3
    call boundsuv(wtul(:,:,i),wtvl(:,:,i),stag=-10)
  end do  
  do k = 1,wlev
    where (abs(wtul(ieu,k,0))>1.E-4.and.abs(wtul(1:ifull,k,1))>1.E-4)
      stul(1:ifull,k)=-wtul(1:ifull,k,1)/wtul(ieu,k,0)
      nwtu(1:ifull,0)=wtul(1:ifull,k,0)+stul(:,k)*wtul(ieu,k,2)
      nwtu(1:ifull,1)=wtul(1:ifull,k,1)+stul(:,k)*wtul(ieu,k,0)
      nwtu(1:ifull,2)=wtul(1:ifull,k,2)
      nwtu(1:ifull,3)=wtul(1:ifull,k,3)-stul(:,k)*wtul(ieu,k,1)
    elsewhere
      stul(1:ifull,k)=0.
      nwtu(1:ifull,0)=wtul(1:ifull,k,0)
      nwtu(1:ifull,1)=wtul(1:ifull,k,1)
      nwtu(1:ifull,2)=wtul(1:ifull,k,2)
      nwtu(1:ifull,3)=wtul(1:ifull,k,3)
    end where
    where (abs(wtvl(inv,k,0))>1.E-4.and.abs(wtvl(1:ifull,k,1))>1.E-4)
      stvl(1:ifull,k)=-wtvl(1:ifull,k,1)/wtvl(inv,k,0)
      nwtv(1:ifull,0)=wtvl(1:ifull,k,0)+stvl(:,k)*wtvl(inv,k,2)
      nwtv(1:ifull,1)=wtvl(1:ifull,k,1)+stvl(:,k)*wtvl(inv,k,0)
      nwtv(1:ifull,2)=wtvl(1:ifull,k,2)
      nwtv(1:ifull,3)=wtvl(1:ifull,k,3)-stvl(:,k)*wtvl(inv,k,1)
    elsewhere
      stvl(1:ifull,k)=0.
      nwtv(1:ifull,0)=wtvl(1:ifull,k,0)
      nwtv(1:ifull,1)=wtvl(1:ifull,k,1)
      nwtv(1:ifull,2)=wtvl(1:ifull,k,2)
      nwtv(1:ifull,3)=wtvl(1:ifull,k,3)
    end where
    where (abs(wtul(1:ifull,k,0))<1.E-4)
      wtul(1:ifull,k,0)=1.
      wtul(1:ifull,k,1)=0.
      wtul(1:ifull,k,2)=0.
      wtul(1:ifull,k,3)=0.
    elsewhere
      wtul(1:ifull,k,0)=nwtu(1:ifull,0)
      wtul(1:ifull,k,1)=nwtu(1:ifull,1)
      wtul(1:ifull,k,2)=nwtu(1:ifull,2)
      wtul(1:ifull,k,3)=nwtu(1:ifull,3)
    end where
    where (abs(wtvl(1:ifull,k,0))<1.E-4)
      wtvl(1:ifull,k,0)=1.
      wtvl(1:ifull,k,1)=0.
      wtvl(1:ifull,k,2)=0.
      wtvl(1:ifull,k,3)=0.
    elsewhere
      wtvl(1:ifull,k,0)=nwtv(1:ifull,0)
      wtvl(1:ifull,k,1)=nwtv(1:ifull,1)
      wtvl(1:ifull,k,2)=nwtv(1:ifull,2)
      wtvl(1:ifull,k,3)=nwtv(1:ifull,3)
    end where
  end do
    
  ! normalise
  do i = 0,3
    call boundsuv(wtul(:,:,i),wtvl(:,:,i),stag=-10)
  end do  
  do k = 1,wlev
    do i=1,3
      dtul(1:ifull,k,i)=dtul(1:ifull,k,i)/wtul(1:ifull,k,0)
      dtvl(1:ifull,k,i)=dtvl(1:ifull,k,i)/wtvl(1:ifull,k,0)
      wtul(1:ifull,k,i)=wtul(1:ifull,k,i)/wtul(1:ifull,k,0)
      wtvl(1:ifull,k,i)=wtvl(1:ifull,k,i)/wtvl(1:ifull,k,0)
    end do
    stul(1:ifull,k)=stul(1:ifull,k)*wtul(ieu,k,0)/wtul(1:ifull,k,0)
    stvl(1:ifull,k)=stvl(1:ifull,k)*wtvl(inv,k,0)/wtvl(1:ifull,k,0)
    wtul(1:ifull,k,0)=1.
    wtvl(1:ifull,k,0)=1.
  end do  

  ! assign weights (right)
  do k = 1,wlev
    eutest = ee(1:ifull,k)*ee(ie,k)>0.5
    evtest = ee(1:ifull,k)*ee(in,k)>0.5
    euetest = eutest     .and. ee(ie,k)*ee(iee,k)>0.5
    euwtest = ee(iw,k)*ee(1:ifull,k)>0.5 .and. eutest
    evntest = evtest     .and. ee(in,k)*ee(inn,k)>0.5
    evstest = ee(is,k)*ee(1:ifull,k)>0.5 .and. evtest
    euewtest = euetest .and. euwtest
    evnstest = evntest .and. evstest
 
    ! |   W   |   * X |  E   |     unstaggered
    !         W     X *      E     staggered
    where (euewtest)
      wtur(1:ifull,k,0)=1.
      wtur(1:ifull,k,1)=-0.1
      wtur(1:ifull,k,2)=-0.5
      wtur(1:ifull,k,3)=0.
      dtur(1:ifull,k,1)=0.1
      dtur(1:ifull,k,2)=1.
      dtur(1:ifull,k,3)=0.5

    ! |   W   |   * X |  E   #     unstaggered
    !         W     X *      0     staggered
    elsewhere (euwtest)
      wtur(1:ifull,k,0)=1.
      wtur(1:ifull,k,1)=0.
      wtur(1:ifull,k,2)=-0.5
      wtur(1:ifull,k,3)=0.
      dtur(1:ifull,k,1)=0.1
      dtur(1:ifull,k,2)=1.
      dtur(1:ifull,k,3)=0.5

    ! #  ##   #   * X |   E   |     unstaggered
    ! #  ##   0     X *             staggered
    elsewhere (euetest)
      wtur(1:ifull,k,0)=1.
      wtur(1:ifull,k,1)=0.
      wtur(1:ifull,k,2)=0.
      wtur(1:ifull,k,3)=0.
      dtur(1:ifull,k,1)=0.
      dtur(1:ifull,k,2)=1.
      dtur(1:ifull,k,3)=1./3.

    ! #  ##   #   *   |  E   #     unstaggered
    ! #  ##   #       *      #     staggered
    elsewhere (eutest)
      wtur(1:ifull,k,0)=1.
      wtur(1:ifull,k,1)=0.
      wtur(1:ifull,k,2)=0.
      wtur(1:ifull,k,3)=0.
      dtur(1:ifull,k,1)=0.
      dtur(1:ifull,k,2)=0.5
      dtur(1:ifull,k,3)=0.5
    elsewhere
      wtur(1:ifull,k,0)=0.
      wtur(1:ifull,k,1)=0.
      wtur(1:ifull,k,2)=0.
      wtur(1:ifull,k,3)=0.
      dtur(1:ifull,k,1)=0.
      dtur(1:ifull,k,2)=0.
      dtur(1:ifull,k,3)=0.
      
    end where
    where (evnstest)
      wtvr(1:ifull,k,0)=1.
      wtvr(1:ifull,k,1)=-0.1
      wtvr(1:ifull,k,2)=-0.5
      wtvr(1:ifull,k,3)=0.
      dtvr(1:ifull,k,1)=0.1
      dtvr(1:ifull,k,2)=1.
      dtvr(1:ifull,k,3)=0.5
    elsewhere (evstest)
      wtvr(1:ifull,k,0)=1.
      wtvr(1:ifull,k,1)=0.
      wtvr(1:ifull,k,2)=-0.5
      wtvr(1:ifull,k,3)=0.
      dtvr(1:ifull,k,1)=0.1
      dtvr(1:ifull,k,2)=1.
      dtvr(1:ifull,k,3)=0.5
    elsewhere (evntest)
      wtvr(1:ifull,k,0)=1.
      wtvr(1:ifull,k,1)=0.
      wtvr(1:ifull,k,2)=0.
      wtvr(1:ifull,k,3)=0.
      dtvr(1:ifull,k,1)=0.
      dtvr(1:ifull,k,2)=1.
      dtvr(1:ifull,k,3)=1./3.
    elsewhere (evtest)
      wtvr(1:ifull,k,0)=1.
      wtvr(1:ifull,k,1)=0.
      wtvr(1:ifull,k,2)=0.
      wtvr(1:ifull,k,3)=0.
      dtvr(1:ifull,k,1)=0.
      dtvr(1:ifull,k,2)=0.5
      dtvr(1:ifull,k,3)=0.5
    elsewhere
      wtvr(1:ifull,k,0)=0.
      wtvr(1:ifull,k,1)=0.
      wtvr(1:ifull,k,2)=0.
      wtvr(1:ifull,k,3)=0.
      dtvr(1:ifull,k,1)=0.
      dtvr(1:ifull,k,2)=0.
      dtvr(1:ifull,k,3)=0.
    end where
  end do  

  ! Apply JLM's preconditioner
  do i = 0,3
    call boundsuv(wtur(:,:,i),wtvr(:,:,i),stag=-9)
  end do  
  do k = 1,wlev
    where (abs(wtur(iwu,k,0))>1.E-4.and.abs(wtur(1:ifull,k,2))>1.E-4)
      stur(1:ifull,k)=-wtur(1:ifull,k,2)/wtur(iwu,k,0)
      nwtu(1:ifull,0)=wtur(1:ifull,k,0)+stur(:,k)*wtur(iwu,k,1)
      nwtu(1:ifull,1)=wtur(1:ifull,k,1)
      nwtu(1:ifull,2)=wtur(1:ifull,k,2)+stur(:,k)*wtur(iwu,k,0)
      nwtu(1:ifull,3)=wtur(1:ifull,k,3)-stur(:,k)*wtur(iwu,k,2)
    elsewhere
      stur(1:ifull,k)=0.
      nwtu(1:ifull,0)=wtur(1:ifull,k,0)
      nwtu(1:ifull,1)=wtur(1:ifull,k,1)
      nwtu(1:ifull,2)=wtur(1:ifull,k,2)
      nwtu(1:ifull,3)=wtur(1:ifull,k,3)
    end where
    where (abs(wtvr(isv,k,0))>1.E-4.and.abs(wtvr(1:ifull,k,2))>1.E-4)
      stvr(1:ifull,k)=-wtvr(1:ifull,k,2)/wtvr(isv,k,0)
      nwtv(1:ifull,0)=wtvr(1:ifull,k,0)+stvr(:,k)*wtvr(isv,k,1)
      nwtv(1:ifull,1)=wtvr(1:ifull,k,1)
      nwtv(1:ifull,2)=wtvr(1:ifull,k,2)+stvr(:,k)*wtvr(isv,k,0)
      nwtv(1:ifull,3)=wtvr(1:ifull,k,3)-stvr(:,k)*wtvr(isv,k,2)
    elsewhere
      stvr(1:ifull,k)=0.
      nwtv(1:ifull,0)=wtvr(1:ifull,k,0)
      nwtv(1:ifull,1)=wtvr(1:ifull,k,1)
      nwtv(1:ifull,2)=wtvr(1:ifull,k,2)
      nwtv(1:ifull,3)=wtvr(1:ifull,k,3)
    end where
    where (abs(wtur(1:ifull,k,0))<1.E-4)
      wtur(1:ifull,k,0)=1.
      wtur(1:ifull,k,1)=0.
      wtur(1:ifull,k,2)=0.
      wtur(1:ifull,k,3)=0.
    elsewhere
      wtur(1:ifull,k,0)=nwtu(1:ifull,0)
      wtur(1:ifull,k,1)=nwtu(1:ifull,1)
      wtur(1:ifull,k,2)=nwtu(1:ifull,2)
      wtur(1:ifull,k,3)=nwtu(1:ifull,3)
    end where
    where (abs(wtvr(1:ifull,k,0))<1.E-4)
      wtvr(1:ifull,k,0)=1.
      wtvr(1:ifull,k,1)=0.
      wtvr(1:ifull,k,2)=0.
      wtvr(1:ifull,k,3)=0.
    elsewhere
      wtvr(1:ifull,k,0)=nwtv(1:ifull,0)
      wtvr(1:ifull,k,1)=nwtv(1:ifull,1)
      wtvr(1:ifull,k,2)=nwtv(1:ifull,2)
      wtvr(1:ifull,k,3)=nwtv(1:ifull,3)
    end where
  end do  

  ! normalise
  do i = 0,3
     call boundsuv(wtur(:,:,i),wtvr(:,:,i),stag=-9)
  end do  
  do k = 1,wlev
    do i = 1,3
      dtur(1:ifull,k,i)=dtur(1:ifull,k,i)/wtur(1:ifull,k,0)
      dtvr(1:ifull,k,i)=dtvr(1:ifull,k,i)/wtvr(1:ifull,k,0)
      wtur(1:ifull,k,i)=wtur(1:ifull,k,i)/wtur(1:ifull,k,0)
      wtvr(1:ifull,k,i)=wtvr(1:ifull,k,i)/wtvr(1:ifull,k,0)
    end do
    stur(1:ifull,k)=stur(1:ifull,k)*wtur(iwu,k,0)/wtur(1:ifull,k,0)
    stvr(1:ifull,k)=stvr(1:ifull,k)*wtvr(isv,k,0)/wtvr(1:ifull,k,0)
    wtur(1:ifull,k,0)=1.
    wtvr(1:ifull,k,0)=1.
  end do  
  
end if

kx = size(u,2)
kn = min(kx,wlev)

do k = 1,kn
  uin(1:ifull,k)=u(1:ifull,k)*ee(1:ifull,k)
  vin(1:ifull,k)=v(1:ifull,k)*ee(1:ifull,k)
end do
do k = kn+1,kx
  uin(1:ifull,k)=u(1:ifull,k)*ee(1:ifull,1)
  vin(1:ifull,k)=v(1:ifull,k)*ee(1:ifull,1)
end do

if ( mstagf==0 ) then
  ltest = .true.
else if ( mstagf<0 ) then
  ltest = .false.
else
  ! using ktau-1 ensures that the staggering is relative to the C grid
  ltest = mod(ktau-koff-nstagoffmlo,2*mstagf)<mstagf
end if

if ( ltest ) then

  call boundsuv(uin,vin,stag=1)
  do k = 1,kn
    do concurrent (iq = 1:ifull)  
      ud(iq,k)=dtul(iq,k,1)*uin(ieeu(iq),k)+dtul(iq,k,2)*uin(ieu(iq),k)+dtul(iq,k,3)*uin(iq,k)
      vd(iq,k)=dtvl(iq,k,1)*vin(innv(iq),k)+dtvl(iq,k,2)*vin(inv(iq),k)+dtvl(iq,k,3)*vin(iq,k)
    end do  
  end do
  do k = kn+1,kx
    do concurrent (iq = 1:ifull)  
      ud(iq,k)=dtul(iq,1,1)*uin(ieeu(iq),k)+dtul(iq,1,2)*uin(ieu(iq),k)+dtul(iq,1,3)*uin(iq,k)
      vd(iq,k)=dtvl(iq,1,1)*vin(innv(iq),k)+dtvl(iq,1,2)*vin(inv(iq),k)+dtvl(iq,1,3)*vin(iq,k)
    end do  
  end do
  
  call boundsuv(ud,vd,stag=-10)
  do k = 1,kn
    ! Apply JLM's preconditioner
    ua(1:ifull,k) = ud(1:ifull,k)-stul(1:ifull,k)*ud(ieu,k)
    va(1:ifull,k) = vd(1:ifull,k)-stvl(1:ifull,k)*vd(inv,k)
  end do
  do k = kn+1,kx
    ! Apply JLM's preconditioner
    ua(1:ifull,k) = ud(1:ifull,k)-stul(1:ifull,1)*ud(ieu,k)
    va(1:ifull,k) = vd(1:ifull,k)-stvl(1:ifull,1)*vd(inv,k)
  end do

  ! There are many ways to handle staggering near coastlines.
  ! This version supports the following properties:
  ! - Staggering is exactly reversible for the staggered (C grid) frame
  ! - Zero flux at land boundaries
  ! - The wave amplitude should be preserved

  !!$acc data create(ud,vd,ua,va,uin,vin,wtul,wtvl,ieu,inv,iwu,isv,ieeu,innv)
  !!$acc update device(wtul,wtvl,ieu,inv,iwu,isv,ieeu,innv)
  !!$acc update device(ua(1:ifull,:),va(1:ifull,:))

  !!$acc parallel loop collapse(2) present(ud,vd,ua,va)
  do k = 1,kx
    do concurrent (iq = 1:ifull)  
      ud(iq,k) = ua(iq,k)
      vd(iq,k) = va(iq,k)
    end do
  end do
  !!$acc end parallel loop

  do itn = 1,itnmax        ! each loop is a double iteration
    call boundsuv(ua,va,stag=2)
    !!$acc update device(ua(ifull+1:ifull+iextra,:),va(ifull+1:ifull+iextra,:))
    !!$acc parallel loop collapse(2) present(ud,vd,ua,va,uin,vin,iwu,isv,ieeu,innv)
    do k = 1,kn
      do concurrent (iq = 1:ifull)  
        uin(iq,k)=ud(iq,k)+wtul(iq,k,1)*ua(ieu(iq),k)+wtul(iq,k,2)*ua(iwu(iq),k)+wtul(iq,k,3)*ua(ieeu(iq),k)
        vin(iq,k)=vd(iq,k)+wtvl(iq,k,1)*va(inv(iq),k)+wtvl(iq,k,2)*va(isv(iq),k)+wtvl(iq,k,3)*va(innv(iq),k)
      end do  
    end do
    !!$acc end parallel loop
    !!$acc parallel loop collapse(2) present(ud,vd,ua,va,uin,vin,iwu,isv,ieeu,innv)
    do k = kn+1,kx
      do concurrent (iq = 1:ifull)  
        uin(iq,k)=ud(iq,k)+wtul(iq,1,1)*ua(ieu(iq),k)+wtul(iq,1,2)*ua(iwu(iq),k)+wtul(iq,1,3)*ua(ieeu(iq),k)
        vin(iq,k)=vd(iq,k)+wtvl(iq,1,1)*va(inv(iq),k)+wtvl(iq,1,2)*va(isv(iq),k)+wtvl(iq,1,3)*va(innv(iq),k)
      end do  
    end do
    !!$acc end parallel loop
    !!$acc update self(uin(1:ifull,:),vin(1:ifull,:))
    call boundsuv(uin,vin,stag=2)
    !!$acc update device(uin(ifull+1:ifull+iextra,:),vin(ifull+1:ifull+iextra,:))
    !!$acc parallel loop collapse(2) present(ud,vd,ua,va,uin,vin,iwu,isv,ieeu,innv)
    do k = 1,kn
      do concurrent (iq = 1:ifull)  
        ua(iq,k)=ud(iq,k)+wtul(iq,k,1)*uin(ieu(iq),k)+wtul(iq,k,2)*uin(iwu(iq),k)+wtul(iq,k,3)*uin(ieeu(iq),k)
        va(iq,k)=vd(iq,k)+wtvl(iq,k,1)*vin(inv(iq),k)+wtvl(iq,k,2)*vin(isv(iq),k)+wtvl(iq,k,3)*vin(innv(iq),k)
      end do  
    end do
    !!$acc end parallel loop
    !!$acc parallel loop collapse(2) present(ud,vd,ua,va,uin,vin,iwu,isv,ieeu,innv)
    do k = kn+1,kx
      do concurrent (iq = 1:ifull)  
        ua(iq,k)=ud(iq,k)+wtul(iq,1,1)*uin(ieu(iq),k)+wtul(iq,1,2)*uin(iwu(iq),k)+wtul(iq,1,3)*uin(ieeu(iq),k)
        va(iq,k)=vd(iq,k)+wtvl(iq,1,1)*vin(inv(iq),k)+wtvl(iq,1,2)*vin(isv(iq),k)+wtvl(iq,1,3)*vin(innv(iq),k)
      end do  
    end do
    !!$acc end parallel loop
    !!$acc update self(ua(1:ifull,:),va(1:ifull,:))
  end do                 ! itn=1,itnmax
 
  !!$acc end data

else

  call boundsuv(uin,vin)
  do k = 1,kn
    do concurrent (iq = 1:ifull)  
      ud(iq,k)=dtur(iq,k,1)*uin(iwu(iq),k)+dtur(iq,k,2)*uin(iq,k)+dtur(iq,k,3)*uin(ieu(iq),k)
      vd(iq,k)=dtvr(iq,k,1)*vin(isv(iq),k)+dtvr(iq,k,2)*vin(iq,k)+dtvr(iq,k,3)*vin(inv(iq),k)
    end do  
  end do
  do k = kn+1,kx
    do concurrent (iq = 1:ifull)  
      ud(iq,k)=dtur(iq,1,1)*uin(iwu(iq),k)+dtur(iq,1,2)*uin(iq,k)+dtur(iq,1,3)*uin(ieu(iq),k)
      vd(iq,k)=dtvr(iq,1,1)*vin(isv(iq),k)+dtvr(iq,1,2)*vin(iq,k)+dtvr(iq,1,3)*vin(inv(iq),k)
    end do  
  end do

  call boundsuv(ud,vd,stag=-9)
  do k = 1,kn
    ! Apply JLM's preconditioner
    ua(1:ifull,k) = ud(1:ifull,k)-stur(1:ifull,k)*ud(iwu,k)
    va(1:ifull,k) = vd(1:ifull,k)-stvr(1:ifull,k)*vd(isv,k)
  end do
  do k = kn+1,kx
    ! Apply JLM's preconditioner
    ua(1:ifull,k) = ud(1:ifull,k)-stur(1:ifull,1)*ud(iwu,k)
    va(1:ifull,k) = vd(1:ifull,k)-stvr(1:ifull,1)*vd(isv,k)
  end do

  !!$acc data create(ud,vd,ua,va,uin,vin,wtur,wtvr,ieu,inv,iwu,isv,iwwu,issv)
  !!$acc update device(wtur,wtvr,ieu,inv,iwu,isv,iwwu,issv)
  !!$acc update device(ua(1:ifull,:),va(1:ifull,:))

  !!$acc parallel loop collapse(2) present(ud,vd,ua,va)
  do k = 1,kx
    do concurrent (iq = 1:ifull)  
      ud(iq,k) = ua(iq,k)
      vd(iq,k) = va(iq,k)
    end do
  end do
  !!$acc end parallel loop

  do itn = 1,itnmax        ! each loop is a double iteration
    call boundsuv(ua,va,stag=3)
    !!$acc update device(ua(ifull+1:ifull+iextra,:),va(ifull+1:ifull+iextra,:))
    !!$acc parallel loop collapse(2) present(ud,vd,ua,va,uin,vin,ieu,inv,iwu,isv,iwwu,issv,wtur,wtvr)
    do k = 1,kn
      do concurrent (iq = 1:ifull)  
        uin(iq,k)=ud(iq,k)+wtur(iq,k,1)*ua(ieu(iq),k)+wtur(iq,k,2)*ua(iwu(iq),k)+wtur(iq,k,3)*ua(iwwu(iq),k)
        vin(iq,k)=vd(iq,k)+wtvr(iq,k,1)*va(inv(iq),k)+wtvr(iq,k,2)*va(isv(iq),k)+wtvr(iq,k,3)*va(issv(iq),k)
      end do  
    end do
    !!$acc end parallel loop
    !!$acc parallel loop collapse(2) present(ud,vd,ua,va,uin,vin,ieu,inv,iwu,isv,iwwu,issv,wtur,wtvr)
    do k = kn+1,kx
      do concurrent (iq = 1:ifull)  
        uin(iq,k)=ud(iq,k)+wtur(iq,1,1)*ua(ieu(iq),k)+wtur(iq,1,2)*ua(iwu(iq),k)+wtur(iq,1,3)*ua(iwwu(iq),k)
        vin(iq,k)=vd(iq,k)+wtvr(iq,1,1)*va(inv(iq),k)+wtvr(iq,1,2)*va(isv(iq),k)+wtvr(iq,1,3)*va(issv(iq),k)
      end do  
    end do
    !!$acc end parallel loop
    !!$acc update self(uin(1:ifull,:),vin(1:ifull,:))
    call boundsuv(uin,vin,stag=3)
    !!$acc update device(uin(ifull+1:ifull+iextra,:),vin(ifull+1:ifull+iextra,:))
    !!$acc parallel loop collapse(2) present(ud,vd,ua,va,uin,vin,ieu,inv,iwu,isv,iwwu,issv,wtur,wtvr)
    do k = 1,kn
      do concurrent (iq = 1:ifull)  
        ua(iq,k)=ud(iq,k)+wtur(iq,k,1)*uin(ieu(iq),k)+wtur(iq,k,2)*uin(iwu(iq),k)+wtur(iq,k,3)*uin(iwwu(iq),k)
        va(iq,k)=vd(iq,k)+wtvr(iq,k,1)*vin(inv(iq),k)+wtvr(iq,k,2)*vin(isv(iq),k)+wtvr(iq,k,3)*vin(issv(iq),k)
      end do  
    end do
    !!$acc end parallel loop
    !!$acc parallel loop collapse(2) present(ud,vd,ua,va,uin,vin,ieu,inv,iwu,isv,iwwu,issv,wtur,wtvr)
    do k = kn+1,kx
      do concurrent (iq = 1:ifull)  
        ua(iq,k)=ud(iq,k)+wtur(iq,1,1)*uin(ieu(iq),k)+wtur(iq,1,2)*uin(iwu(iq),k)+wtur(iq,1,3)*uin(iwwu(iq),k)
        va(iq,k)=vd(iq,k)+wtvr(iq,1,1)*vin(inv(iq),k)+wtvr(iq,1,2)*vin(isv(iq),k)+wtvr(iq,1,3)*vin(issv(iq),k)
      end do  
    end do
    !!$acc end parallel loop
    !!$acc update self(ua(1:ifull,:),va(1:ifull,:))
  end do                 ! itn=1,itnmax

  !!$acc end data

end if

do k = 1,kn
  uout(1:ifull,k)=ua(1:ifull,k)*eeu(1:ifull,k)
  vout(1:ifull,k)=va(1:ifull,k)*eev(1:ifull,k)
end do
do k = kn+1,kx
  uout(1:ifull,k)=ua(1:ifull,k)*eeu(1:ifull,1)
  vout(1:ifull,k)=va(1:ifull,k)*eev(1:ifull,1)
end do

call END_LOG(ocnstag_end)

return
end subroutine mlostaguv

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Unstagger u and v
! Modified to include zero velocity over land points
subroutine mlounstaguv(u,v,uout,vout,toff)

use cc_mpi
use indices_m
use mlo
use newmpar_m
use parm_m

implicit none

integer, intent(in), optional :: toff
integer i,k,itn,kx,kn,zoff,iq
real, dimension(:,:), intent(in) :: u,v
real, dimension(:,:), intent(out) :: uout,vout
real, dimension(ifull+iextra,size(u,2)) :: uin,vin
real, dimension(ifull+iextra,size(u,2)) :: ua,va
real, dimension(ifull+iextra,size(u,2)) :: ud,vd
real, dimension(ifull,0:3) :: nwtu,nwtv
real, dimension(:,:,:), allocatable, save :: wtul,wtvl
real, dimension(:,:,:), allocatable, save :: wtur,wtvr
real, dimension(:,:,:), allocatable, save :: dtul,dtvl
real, dimension(:,:,:), allocatable, save :: dtur,dtvr
real, dimension(:,:), allocatable, save :: stul,stvl
real, dimension(:,:), allocatable, save :: stur,stvr
logical, dimension(ifull) :: eutest,evtest
logical, dimension(ifull) :: eetest,ewtest,entest,estest
logical, dimension(ifull) :: euetest,euwtest,evntest,evstest
logical, dimension(ifull) :: euewtest,evnstest
logical, dimension(ifull) :: eeetest,ewwtest,enntest,esstest
logical ltest

call START_LOG(ocnstag_begin)

if (.not.allocated(wtul)) then
  allocate(wtul(ifull+iextra,wlev,0:3),wtvl(ifull+iextra,wlev,0:3))
  allocate(wtur(ifull+iextra,wlev,0:3),wtvr(ifull+iextra,wlev,0:3))
  allocate(dtul(ifull,wlev,3),dtvl(ifull,wlev,3))
  allocate(dtur(ifull,wlev,3),dtvr(ifull,wlev,3))
  allocate(stul(ifull,wlev),stvl(ifull,wlev))
  allocate(stur(ifull,wlev),stvr(ifull,wlev))

  do k = 1,wlev
    ! assign land arrays
    eetest = ee(1:ifull,k)*ee(ie,k)>0.5
    ewtest = ee(iw,k)*ee(1:ifull,k)>0.5
    entest = ee(1:ifull,k)*ee(in,k)>0.5
    estest = ee(is,k)*ee(1:ifull,k)>0.5

    eutest = ee(iw,k)*ee(1:ifull,k)>0.5
    evtest = ee(is,k)*ee(1:ifull,k)>0.5
    euetest = eutest .and. ee(1:ifull,k)*ee(ie,k)>0.5
    evntest = evtest .and. ee(1:ifull,k)*ee(in,k)>0.5
    euwtest = eutest .and. ee(iww,k)*ee(iw,k)>0.5
    evstest = evtest .and. ee(iss,k)*ee(is,k)>0.5
    euewtest = euetest .and. euwtest
    evnstest = evntest .and. evstest
    eeetest = eetest .and. ee(iee,k)>0.5
    enntest = entest .and. ee(inn,k)>0.5

    ! assign weights (left)

    !  |   W   | X *   |  E   |     unstaggered
    ! WW       W X     *            staggered
    where (euewtest)
      wtul(1:ifull,k,0)=1.
      wtul(1:ifull,k,1)=-0.1
      wtul(1:ifull,k,2)=-0.5
      wtul(1:ifull,k,3)=0.
      dtul(1:ifull,k,1)=0.1
      dtul(1:ifull,k,2)=1.
      dtul(1:ifull,k,3)=0.5
      !ud(1:ifull,k)=uin(iwwu,k)*0.1+uin(iwu,k)+uin(1:ifull,k)*0.5
      !uin(1:ifull,k)=ud(:,k)-ua(ieu,k)*0.1-ua(iwu,k)*0.5

    ! ##   W   | X *   |  E   |     unstaggered
    ! #0       W X     *            staggered
    elsewhere (euetest)
      wtul(1:ifull,k,0)=1.
      wtul(1:ifull,k,1)=-0.1
      wtul(1:ifull,k,2)=-0.5
      wtul(1:ifull,k,3)=0.
      dtul(1:ifull,k,1)=0.
      dtul(1:ifull,k,2)=1.
      dtul(1:ifull,k,3)=0.5
      
    !  |   W   | X *   #  ##  #     unstaggered
    !          W X     0  ##  #     staggered
    elsewhere (euwtest)
      wtul(1:ifull,k,0)=1.
      wtul(1:ifull,k,1)=0.
      wtul(1:ifull,k,2)=-1./3.
      wtul(1:ifull,k,3)=0.
      dtul(1:ifull,k,1)=0.
      dtul(1:ifull,k,2)=1.
      dtul(1:ifull,k,3)=0.

    ! ##   ##  #   * X |   E   |     unstaggered
    ! ##   ##  0     X *             staggered
    elsewhere (eeetest)
      wtul(1:ifull,k,0)=1.
      wtul(1:ifull,k,1)=-1./3.
      wtul(1:ifull,k,2)=0.
      wtul(1:ifull,k,3)=0.
      dtul(1:ifull,k,1)=0.
      dtul(1:ifull,k,2)=0.
      dtul(1:ifull,k,3)=1.

    ! ##   ##  #   *   |   E    #     unstaggered
    ! ##   ##  #       *        #     staggered
    elsewhere (eetest)
      wtul(1:ifull,k,0)=1.
      wtul(1:ifull,k,1)=0.
      wtul(1:ifull,k,2)=0.
      wtul(1:ifull,k,3)=0.
      dtul(1:ifull,k,1)=0.
      dtul(1:ifull,k,2)=0.
      dtul(1:ifull,k,3)=1.

    ! ##   W   |   *   #  ##  #     unstaggered
    ! ##       W       #  ##  #     staggered
    elsewhere (eutest)
      wtul(1:ifull,k,0)=1.
      wtul(1:ifull,k,1)=0.
      wtul(1:ifull,k,2)=0.
      wtul(1:ifull,k,3)=0.
      dtul(1:ifull,k,1)=0.
      dtul(1:ifull,k,2)=1.
      dtul(1:ifull,k,3)=0.

    elsewhere
      wtul(1:ifull,k,0)=0.
      wtul(1:ifull,k,1)=0.
      wtul(1:ifull,k,2)=0.
      wtul(1:ifull,k,3)=0.
      dtul(1:ifull,k,1)=0.
      dtul(1:ifull,k,2)=0.
      dtul(1:ifull,k,3)=0.
      
    end where
    where (evnstest)
      wtvl(1:ifull,k,0)=1.
      wtvl(1:ifull,k,1)=-0.1
      wtvl(1:ifull,k,2)=-0.5
      wtvl(1:ifull,k,3)=0.
      dtvl(1:ifull,k,1)=0.1
      dtvl(1:ifull,k,2)=1.
      dtvl(1:ifull,k,3)=0.5
      !vd(1:ifull,k)=vin(issv,k)*0.1+vin(isv,k)+vin(1:ifull,k)*0.5
      !vin(1:ifull,k)=vd(:,k)-va(inv,k)*0.1-va(isv,k)*0.5
    elsewhere (evntest)
      wtvl(1:ifull,k,0)=1.
      wtvl(1:ifull,k,1)=-0.1
      wtvl(1:ifull,k,2)=-0.5
      wtvl(1:ifull,k,3)=0.
      dtvl(1:ifull,k,1)=0.
      dtvl(1:ifull,k,2)=1.
      dtvl(1:ifull,k,3)=0.5
    elsewhere (evstest)
      wtvl(1:ifull,k,0)=1.
      wtvl(1:ifull,k,1)=0.
      wtvl(1:ifull,k,2)=-1./3.
      wtvl(1:ifull,k,3)=0.
      dtvl(1:ifull,k,1)=0.
      dtvl(1:ifull,k,2)=1.
      dtvl(1:ifull,k,3)=0.
    elsewhere (enntest)
      wtvl(1:ifull,k,0)=1.
      wtvl(1:ifull,k,1)=-1./3.
      wtvl(1:ifull,k,2)=0.
      wtvl(1:ifull,k,3)=0.
      dtvl(1:ifull,k,1)=0.
      dtvl(1:ifull,k,2)=0.
      dtvl(1:ifull,k,3)=1.
    elsewhere (entest)
      wtvl(1:ifull,k,0)=1.
      wtvl(1:ifull,k,1)=0.
      wtvl(1:ifull,k,2)=0.
      wtvl(1:ifull,k,3)=0.
      dtvl(1:ifull,k,1)=0.
      dtvl(1:ifull,k,2)=0.
      dtvl(1:ifull,k,3)=1.
    elsewhere (evtest)
      wtvl(1:ifull,k,0)=1.
      wtvl(1:ifull,k,1)=0.
      wtvl(1:ifull,k,2)=0.
      wtvl(1:ifull,k,3)=0.
      dtvl(1:ifull,k,1)=0.
      dtvl(1:ifull,k,2)=1.
      dtvl(1:ifull,k,3)=0.
    elsewhere
      wtvl(1:ifull,k,0)=0.
      wtvl(1:ifull,k,1)=0.
      wtvl(1:ifull,k,2)=0.
      wtvl(1:ifull,k,3)=0.
      dtvl(1:ifull,k,1)=0.
      dtvl(1:ifull,k,2)=0.
      dtvl(1:ifull,k,3)=0.
    end where
  end do  
    
  ! Apply JLM's preconditioner
  do i = 0,3
     call boundsuv(wtul(:,:,i),wtvl(:,:,i),stag=-9)
  end do   
  do k = 1,wlev
    where (abs(wtul(iwu,k,0))>1.E-4.and.abs(wtul(1:ifull,k,2))>1.E-4)
      stul(1:ifull,k)=-wtul(1:ifull,k,2)/wtul(iwu,k,0)
      nwtu(1:ifull,0)=wtul(1:ifull,k,0)+stul(:,k)*wtul(iwu,k,1)
      nwtu(1:ifull,1)=wtul(1:ifull,k,1)
      nwtu(1:ifull,2)=wtul(1:ifull,k,2)+stul(:,k)*wtul(iwu,k,0)
      nwtu(1:ifull,3)=wtul(1:ifull,k,3)-stul(:,k)*wtul(iwu,k,2)
    elsewhere
      stul(1:ifull,k)=0.
      nwtu(1:ifull,0)=wtul(1:ifull,k,0)
      nwtu(1:ifull,1)=wtul(1:ifull,k,1)
      nwtu(1:ifull,2)=wtul(1:ifull,k,2)
      nwtu(1:ifull,3)=wtul(1:ifull,k,3)
    end where
    where (abs(wtvl(isv,k,0))>1.E-4.and.abs(wtvl(1:ifull,k,2))>1.E-4)
      stvl(1:ifull,k)=-wtvl(1:ifull,k,2)/wtvl(isv,k,0)
      nwtv(1:ifull,0)=wtvl(1:ifull,k,0)+stvl(:,k)*wtvl(isv,k,1)
      nwtv(1:ifull,1)=wtvl(1:ifull,k,1)
      nwtv(1:ifull,2)=wtvl(1:ifull,k,2)+stvl(:,k)*wtvl(isv,k,0)
      nwtv(1:ifull,3)=wtvl(1:ifull,k,3)-stvl(:,k)*wtvl(isv,k,2)
    elsewhere
      stvl(1:ifull,k)=0.
      nwtv(1:ifull,0)=wtvl(1:ifull,k,0)
      nwtv(1:ifull,1)=wtvl(1:ifull,k,1)
      nwtv(1:ifull,2)=wtvl(1:ifull,k,2)
      nwtv(1:ifull,3)=wtvl(1:ifull,k,3)
    end where
    where (abs(wtul(1:ifull,k,0))<1.E-4)
      wtul(1:ifull,k,0)=1.
      wtul(1:ifull,k,1)=0.
      wtul(1:ifull,k,2)=0.
      wtul(1:ifull,k,3)=0.
    elsewhere
      wtul(1:ifull,k,0)=nwtu(1:ifull,0)
      wtul(1:ifull,k,1)=nwtu(1:ifull,1)
      wtul(1:ifull,k,2)=nwtu(1:ifull,2)
      wtul(1:ifull,k,3)=nwtu(1:ifull,3)
    end where
    where (abs(wtvl(1:ifull,k,0))<1.E-4)
      wtvl(1:ifull,k,0)=1.
      wtvl(1:ifull,k,1)=0.
      wtvl(1:ifull,k,2)=0.
      wtvl(1:ifull,k,3)=0.
    elsewhere
      wtvl(1:ifull,k,0)=nwtv(1:ifull,0)
      wtvl(1:ifull,k,1)=nwtv(1:ifull,1)
      wtvl(1:ifull,k,2)=nwtv(1:ifull,2)
      wtvl(1:ifull,k,3)=nwtv(1:ifull,3)
    end where
  end do  

  ! normalise
  do i = 0,3
     call boundsuv(wtul(:,:,i),wtvl(:,:,i),stag=-9)
  end do   
  do k = 1,wlev
    do i = 1,3
      wtul(1:ifull,k,i)=wtul(1:ifull,k,i)/wtul(1:ifull,k,0)
      wtvl(1:ifull,k,i)=wtvl(1:ifull,k,i)/wtvl(1:ifull,k,0)
      dtul(1:ifull,k,i)=dtul(1:ifull,k,i)/wtul(1:ifull,k,0)
      dtvl(1:ifull,k,i)=dtvl(1:ifull,k,i)/wtvl(1:ifull,k,0)
    end do
    stul(1:ifull,k)=stul(1:ifull,k)*wtul(iwu,k,0)/wtul(1:ifull,k,0)
    stvl(1:ifull,k)=stvl(1:ifull,k)*wtvl(isv,k,0)/wtvl(1:ifull,k,0)
    wtul(1:ifull,k,0)=1.
    wtvl(1:ifull,k,0)=1.
  end do  


  ! assign weights (right) 
  do k = 1,wlev
      
    ! assign land arrays  
    eutest=ee(1:ifull,k)*ee(ie,k)>0.5
    evtest=ee(1:ifull,k)*ee(in,k)>0.5
    euetest=eutest.and.ee(ie,k)*ee(iee,k)>0.5
    evntest=evtest.and.ee(in,k)*ee(inn,k)>0.5
    euwtest=eutest.and.ee(iw,k)*ee(1:ifull,k)>0.5
    evstest=evtest.and.ee(is,k)*ee(1:ifull,k)>0.5
    euewtest=euetest.and.euwtest
    evnstest=evntest.and.evstest
    ewwtest=ewtest.and.ee(iww,k)>0.5
    esstest=estest.and.ee(iss,k)>0.5
  
  
    !  |   W   |   * X |  E   |     unstaggered
    !          W     X *      E     staggered
    where (euewtest)
      wtur(1:ifull,k,0)=1.
      wtur(1:ifull,k,1)=-0.5
      wtur(1:ifull,k,2)=-0.1
      wtur(1:ifull,k,3)=0.
      dtur(1:ifull,k,1)=0.1
      dtur(1:ifull,k,2)=1.
      dtur(1:ifull,k,3)=0.5
      !ud(1:ifull,k)=uin(ieu,k)*0.1+uin(1:ifull,k)+uin(iwu,k)*0.5
      !uin(1:ifull,k)=ud(:,k)-ua(iwu,k)*0.1-ua(ieu,k)*0.5
        
    !  |   W   |   * X |  E   #     unstaggered
    !          W     X *      0     staggered
    elsewhere (euwtest)
      wtur(1:ifull,k,0)=1.
      wtur(1:ifull,k,1)=-0.5
      wtur(1:ifull,k,2)=-0.1
      wtur(1:ifull,k,3)=0.
      dtur(1:ifull,k,1)=0.
      dtur(1:ifull,k,2)=1.
      dtur(1:ifull,k,3)=0.5
      
    !  #   ##  #   * X |   E   |     unstaggered
    !  #   ##  0     X *             staggered
    elsewhere (euetest)
      wtur(1:ifull,k,0)=1.
      wtur(1:ifull,k,1)=-1./3.
      wtur(1:ifull,k,2)=0.
      wtur(1:ifull,k,3)=0.
      dtur(1:ifull,k,1)=0.
      dtur(1:ifull,k,2)=1.
      dtur(1:ifull,k,3)=0.

    !  |   W   | X *   #  ##  #     unstaggered
    !          W X     0  ##  #     staggered
    elsewhere (ewwtest)
      wtur(1:ifull,k,0)=1.
      wtur(1:ifull,k,1)=0.
      wtur(1:ifull,k,2)=-1./3.
      wtur(1:ifull,k,3)=0.
      dtur(1:ifull,k,1)=0.
      dtur(1:ifull,k,2)=0.
      dtur(1:ifull,k,3)=1.

    !  #   W   |   *   #  ##  #     unstaggered
    !  #       W       #  ##  #     staggered
    elsewhere (ewtest)
      wtur(1:ifull,k,0)=1.
      wtur(1:ifull,k,1)=0.
      wtur(1:ifull,k,2)=0.
      wtur(1:ifull,k,3)=0.
      dtur(1:ifull,k,1)=0.
      dtur(1:ifull,k,2)=0.
      dtur(1:ifull,k,3)=1.

    !  #   ##  #   *   |  E   #     unstaggered
    !  #   ##  #       *      #     staggered
    elsewhere (eutest)
      wtur(1:ifull,k,0)=1.
      wtur(1:ifull,k,1)=0.
      wtur(1:ifull,k,2)=0.
      wtur(1:ifull,k,3)=0.
      dtur(1:ifull,k,1)=0.
      dtur(1:ifull,k,2)=1.
      dtur(1:ifull,k,3)=0.
    elsewhere
      wtur(1:ifull,k,0)=0.
      wtur(1:ifull,k,1)=0.
      wtur(1:ifull,k,2)=0.
      wtur(1:ifull,k,3)=0.
      dtur(1:ifull,k,1)=0.
      dtur(1:ifull,k,2)=0.
      dtur(1:ifull,k,3)=0.

    end where
    where (evnstest)
      wtvr(1:ifull,k,0)=1.
      wtvr(1:ifull,k,1)=-0.5
      wtvr(1:ifull,k,2)=-0.1
      wtvr(1:ifull,k,3)=0.
      dtvr(1:ifull,k,1)=0.1
      dtvr(1:ifull,k,2)=1.
      dtvr(1:ifull,k,3)=0.5
      !vd(1:ifull,k)=vin(inv,k)*0.1+vin(1:ifull,k)+vin(isv,k)*0.5
      !vin(1:ifull,k)=vd(:,k)-va(isv,k)*0.1-va(inv,k)*0.5
    elsewhere (evstest)
      wtvr(1:ifull,k,0)=1.
      wtvr(1:ifull,k,1)=-0.5
      wtvr(1:ifull,k,2)=-0.1
      wtvr(1:ifull,k,3)=0.
      dtvr(1:ifull,k,1)=0.
      dtvr(1:ifull,k,2)=1.
      dtvr(1:ifull,k,3)=0.5
    elsewhere (evntest)
      wtvr(1:ifull,k,0)=1.
      wtvr(1:ifull,k,1)=-1./3.
      wtvr(1:ifull,k,2)=0.
      wtvr(1:ifull,k,3)=0.
      dtvr(1:ifull,k,1)=0.
      dtvr(1:ifull,k,2)=1.
      dtvr(1:ifull,k,3)=0.
    elsewhere (esstest)
      wtvr(1:ifull,k,0)=1.
      wtvr(1:ifull,k,1)=0.
      wtvr(1:ifull,k,2)=-1./3.
      wtvr(1:ifull,k,3)=0.
      dtvr(1:ifull,k,1)=0.
      dtvr(1:ifull,k,2)=0.
      dtvr(1:ifull,k,3)=1.
    elsewhere (estest)
      wtvr(1:ifull,k,0)=1.
      wtvr(1:ifull,k,1)=0.
      wtvr(1:ifull,k,2)=0.
      wtvr(1:ifull,k,3)=0.
      dtvr(1:ifull,k,1)=0.
      dtvr(1:ifull,k,2)=0.
      dtvr(1:ifull,k,3)=1.
    elsewhere (evtest)
      wtvr(1:ifull,k,0)=1.
      wtvr(1:ifull,k,1)=0.
      wtvr(1:ifull,k,2)=0.
      wtvr(1:ifull,k,3)=0.
      dtvr(1:ifull,k,1)=0.
      dtvr(1:ifull,k,2)=1.
      dtvr(1:ifull,k,3)=0.
    elsewhere
      wtvr(1:ifull,k,0)=0.
      wtvr(1:ifull,k,1)=0.
      wtvr(1:ifull,k,2)=0.
      wtvr(1:ifull,k,3)=0.
      dtvr(1:ifull,k,1)=0.
      dtvr(1:ifull,k,2)=0.
      dtvr(1:ifull,k,3)=0.
    end where
  end do  

  ! Apply JLM's preconditioner
  do i = 0,3
     call boundsuv(wtur(:,:,i),wtvr(:,:,i),stag=-10)
  end do   
  do k = 1,wlev
    where (abs(wtur(ieu,k,0))>1.E-4.and.abs(wtur(1:ifull,k,1))>1.E-4)
      stur(1:ifull,k)=-wtur(1:ifull,k,1)/wtur(ieu,k,0)
      nwtu(1:ifull,0)=wtur(1:ifull,k,0)+stur(:,k)*wtur(ieu,k,2)
      nwtu(1:ifull,1)=wtur(1:ifull,k,1)+stur(:,k)*wtur(ieu,k,0)
      nwtu(1:ifull,2)=wtur(1:ifull,k,2)
      nwtu(1:ifull,3)=wtur(1:ifull,k,3)-stur(:,k)*wtur(ieu,k,1)
    elsewhere
      stur(1:ifull,k)=0.
      nwtu(1:ifull,0)=wtur(1:ifull,k,0)
      nwtu(1:ifull,1)=wtur(1:ifull,k,1)
      nwtu(1:ifull,2)=wtur(1:ifull,k,2)
      nwtu(1:ifull,3)=wtur(1:ifull,k,3)
    end where
    where (abs(wtvr(inv,k,0))>1.E-4.and.abs(wtvr(1:ifull,k,1))>1.E-4)
      stvr(1:ifull,k)=-wtvr(1:ifull,k,1)/wtvr(inv,k,0)
      nwtv(1:ifull,0)=wtvr(1:ifull,k,0)+stvr(:,k)*wtvr(inv,k,2)
      nwtv(1:ifull,1)=wtvr(1:ifull,k,1)+stvr(:,k)*wtvr(inv,k,0)
      nwtv(1:ifull,2)=wtvr(1:ifull,k,2)
      nwtv(1:ifull,3)=wtvr(1:ifull,k,3)-stvr(:,k)*wtvr(inv,k,1)
    elsewhere
      stvr(1:ifull,k)=0.
      nwtv(1:ifull,0)=wtvr(1:ifull,k,0)
      nwtv(1:ifull,1)=wtvr(1:ifull,k,1)
      nwtv(1:ifull,2)=wtvr(1:ifull,k,2)
      nwtv(1:ifull,3)=wtvr(1:ifull,k,3)
    end where
    where (abs(wtur(1:ifull,k,0))<1.E-4)
      wtur(1:ifull,k,0)=1.
      wtur(1:ifull,k,1)=0.
      wtur(1:ifull,k,2)=0.
      wtur(1:ifull,k,3)=0.
    elsewhere
      wtur(1:ifull,k,0)=nwtu(1:ifull,0)
      wtur(1:ifull,k,1)=nwtu(1:ifull,1)
      wtur(1:ifull,k,2)=nwtu(1:ifull,2)
      wtur(1:ifull,k,3)=nwtu(1:ifull,3)
    end where
    where (abs(wtvr(1:ifull,k,0))<1.E-4)
      wtvr(1:ifull,k,0)=1.
      wtvr(1:ifull,k,1)=0.
      wtvr(1:ifull,k,2)=0.
      wtvr(1:ifull,k,3)=0.
    elsewhere
      wtvr(1:ifull,k,0)=nwtv(1:ifull,0)
      wtvr(1:ifull,k,1)=nwtv(1:ifull,1)
      wtvr(1:ifull,k,2)=nwtv(1:ifull,2)
      wtvr(1:ifull,k,3)=nwtv(1:ifull,3)
    end where
  end do  

  ! normalise
  do i = 0,3
    call boundsuv(wtur(:,:,i),wtvr(:,:,i),stag=-10)
  end do  
  do k = 1,wlev
    do i = 1,3
      wtur(1:ifull,k,i)=wtur(1:ifull,k,i)/wtur(1:ifull,k,0)
      wtvr(1:ifull,k,i)=wtvr(1:ifull,k,i)/wtvr(1:ifull,k,0)
      dtur(1:ifull,k,i)=dtur(1:ifull,k,i)/wtur(1:ifull,k,0)
      dtvr(1:ifull,k,i)=dtvr(1:ifull,k,i)/wtvr(1:ifull,k,0)
    end do
    stur(1:ifull,k)=stur(1:ifull,k)*wtur(ieu,k,0)/wtur(1:ifull,k,0)
    stvr(1:ifull,k)=stvr(1:ifull,k)*wtvr(inv,k,0)/wtvr(1:ifull,k,0)
    wtur(1:ifull,k,0)=1.
    wtvr(1:ifull,k,0)=1.
  end do  
 
end if

kx = size(u,2)
kn = min(kx,wlev)

zoff=0
if (present(toff)) then
  if (toff==1) zoff=koff
end if

do k = 1,kn
  uin(1:ifull,k)=u(1:ifull,k)*eeu(1:ifull,k)
  vin(1:ifull,k)=v(1:ifull,k)*eev(1:ifull,k)
end do
do k = kn+1,kx
  uin(1:ifull,k)=u(1:ifull,k)*eeu(1:ifull,1)
  vin(1:ifull,k)=v(1:ifull,k)*eev(1:ifull,1)
end do

if (mstagf==0) then
  ltest = .true.
else if (mstagf<0) then
  ltest = .false.
else
  ltest = mod(ktau-zoff-nstagoffmlo,2*mstagf)<mstagf
end if

if (ltest) then
  
  call boundsuv(uin,vin,stag=5)
  do k = 1,kn
    do concurrent (iq = 1:ifull)  
      ud(iq,k)=dtul(iq,k,1)*uin(iwwu(iq),k)+dtul(iq,k,2)*uin(iwu(iq),k)+dtul(iq,k,3)*uin(iq,k)
      vd(iq,k)=dtvl(iq,k,1)*vin(issv(iq),k)+dtvl(iq,k,2)*vin(isv(iq),k)+dtvl(iq,k,3)*vin(iq,k)
    end do  
  end do
  do k = kn+1,kx
    do concurrent (iq = 1:ifull)  
      ud(iq,k)=dtul(iq,1,1)*uin(iwwu(iq),k)+dtul(iq,1,2)*uin(iwu(iq),k)+dtul(iq,1,3)*uin(iq,k)
      vd(iq,k)=dtvl(iq,1,1)*vin(issv(iq),k)+dtvl(iq,1,2)*vin(isv(iq),k)+dtvl(iq,1,3)*vin(iq,k)
    end do  
  end do
  
  call boundsuv(ud,vd,stag=-9)
  do k=1,kn
    ! Apply JLM's preconditioner
    ua(1:ifull,k) = ud(1:ifull,k)-stul(1:ifull,k)*ud(iwu,k)
    va(1:ifull,k) = vd(1:ifull,k)-stvl(1:ifull,k)*vd(isv,k)
  end do
  do k = kn+1,kx
    ! Apply JLM's preconditioner
    ua(1:ifull,k) = ud(1:ifull,k)-stul(1:ifull,1)*ud(iwu,k)
    va(1:ifull,k) = vd(1:ifull,k)-stvl(1:ifull,1)*vd(isv,k)
  end do

  !!$acc data create(ud,vd,ua,va,uin,vin,wtul,wtvl,ieu,inv,iwu,isv,iwwu,issv)
  !!$acc update device(wtul,wtvl,ieu,inv,iwu,isv,iwwu,issv)
  !!$acc update device(ua(1:ifull,:),va(1:ifull,:))

  !!$acc parallel loop collapse(2) present(ud,vd,ua,va)
  do k = 1,kx
    do concurrent (iq = 1:ifull)  
      ud(iq,k) = ua(iq,k)
      vd(iq,k) = va(iq,k)
    end do
  end do
  !!$acc end parallel loop

  do itn = 1,itnmax        ! each loop is a double iteration
    call boundsuv(ua,va,stag=3)
    !!$acc update device(ua(ifull+1:ifull+iextra,:),va(ifull+1:ifull+iextra,:))
    !!$acc parallel loop collapse(2) present(ud,vd,ua,va,uin,vin,ieu,inv,iwu,isv,iwwu,issv,wtul,wtvl)
    do k = 1,kn
      do concurrent (iq = 1:ifull)  
        uin(iq,k)=ud(iq,k)+wtul(iq,k,1)*ua(ieu(iq),k)+wtul(iq,k,2)*ua(iwu(iq),k)+wtul(iq,k,3)*ua(iwwu(iq),k)
        vin(iq,k)=vd(iq,k)+wtvl(iq,k,1)*va(inv(iq),k)+wtvl(iq,k,2)*va(isv(iq),k)+wtvl(iq,k,3)*va(issv(iq),k)
      end do  
    end do
    !!$acc end parallel loop
    !!$acc parallel loop collapse(2) present(ud,vd,ua,va,uin,vin,ieu,inv,iwu,isv,iwwu,issv,wtul,wtvl)
    do k = kn+1,kx
      do concurrent (iq = 1:ifull)  
        uin(iq,k)=ud(iq,k)+wtul(iq,1,1)*ua(ieu(iq),k)+wtul(iq,1,2)*ua(iwu(iq),k)+wtul(iq,1,3)*ua(iwwu(iq),k)
        vin(iq,k)=vd(iq,k)+wtvl(iq,1,1)*va(inv(iq),k)+wtvl(iq,1,2)*va(isv(iq),k)+wtvl(iq,1,3)*va(issv(iq),k)
      end do  
    end do
    !!$acc end parallel loop
    !!$acc update self(uin(1:ifull,:),vin(1:ifull,:))
    call boundsuv(uin,vin,stag=3)
    !!$acc update device(uin(ifull+1:ifull+iextra,:),vin(ifull+1:ifull+iextra,:))
    !!$acc parallel loop collapse(2) present(ud,vd,ua,va,uin,vin,ieu,inv,iwu,isv,iwwu,issv,wtul,wtvl)
    do k = 1,kn
      do concurrent (iq = 1:ifull)  
        ua(iq,k)=ud(iq,k)+wtul(iq,k,1)*uin(ieu(iq),k)+wtul(iq,k,2)*uin(iwu(iq),k)+wtul(iq,k,3)*uin(iwwu(iq),k)
        va(iq,k)=vd(iq,k)+wtvl(iq,k,1)*vin(inv(iq),k)+wtvl(iq,k,2)*vin(isv(iq),k)+wtvl(iq,k,3)*vin(issv(iq),k)
      end do  
    end do
    !!$acc end parallel loop
    !!$acc parallel loop collapse(2) present(ud,vd,ua,va,uin,vin,ieu,inv,iwu,isv,iwwu,issv,wtul,wtvl)
    do k = kn+1,kx
      do concurrent (iq = 1:ifull)  
        ua(iq,k)=ud(iq,k)+wtul(iq,1,1)*uin(ieu(iq),k)+wtul(iq,1,2)*uin(iwu(iq),k)+wtul(iq,1,3)*uin(iwwu(iq),k)
        va(iq,k)=vd(iq,k)+wtvl(iq,1,1)*vin(inv(iq),k)+wtvl(iq,1,2)*vin(isv(iq),k)+wtvl(iq,1,3)*vin(issv(iq),k)
      end do  
    end do
    !!$acc end parallel loop
    !!$acc update self(ua(1:ifull,:),va(1:ifull,:))
  end do                  ! itn=1,itnmax
  
  !!$acc end data

else

  call boundsuv(uin,vin)
  do k = 1,kn
    do concurrent (iq = 1:ifull)  
      ud(iq,k)=dtur(iq,k,1)*uin(ieu(iq),k)+dtur(iq,k,2)*uin(iq,k)+dtur(iq,k,3)*uin(iwu(iq),k)
      vd(iq,k)=dtvr(iq,k,1)*vin(inv(iq),k)+dtvr(iq,k,2)*vin(iq,k)+dtvr(iq,k,3)*vin(isv(iq),k)
    end do  
  end do
  do k = kn+1,kx
    do concurrent (iq = 1:ifull)  
      ud(iq,k)=dtur(iq,1,1)*uin(ieu(iq),k)+dtur(iq,1,2)*uin(iq,k)+dtur(iq,1,3)*uin(iwu(iq),k)
      vd(iq,k)=dtvr(iq,1,1)*vin(inv(iq),k)+dtvr(iq,1,2)*vin(iq,k)+dtvr(iq,1,3)*vin(isv(iq),k)
    end do  
  end do

  call boundsuv(ud,vd,stag=-10)
  do k = 1,kn
    ! Apply JLM's preconditioner
    ua(1:ifull,k) = ud(1:ifull,k)-stur(1:ifull,k)*ud(ieu,k)
    va(1:ifull,k) = vd(1:ifull,k)-stvr(1:ifull,k)*vd(inv,k)
  end do
  do k = kn+1,kx
    ! Apply JLM's preconditioner
    ua(1:ifull,k) = ud(1:ifull,k)-stur(1:ifull,1)*ud(ieu,k)
    va(1:ifull,k) = vd(1:ifull,k)-stvr(1:ifull,1)*vd(inv,k)
  end do

  !!$acc data create(ud,vd,ua,va,uin,vin,wtur,wtvr,ieu,inv,iwu,isv,ieeu,innv)
  !!$acc update device(wtur,wtvr,ieu,inv,iwu,isv,ieeu,innv)
  !!$acc update device(ua(1:ifull,:),va(1:ifull,:))

  !!$acc parallel loop collapse(2) present(ud,vd,ua,va)
  do k = 1,kx
    do concurrent (iq = 1:ifull)  
      ud(iq,k) = ua(iq,k)
      vd(iq,k) = va(iq,k)
    end do
  end do
  !!$acc end parallel loop

  do itn = 1,itnmax        ! each loop is a double iteration
    call boundsuv(ua,va,stag=2)
    !!$acc update device(ua(ifull+1:ifull+iextra,:),va(ifull+1:ifull+iextra,:))
    !!$acc parallel loop collapse(2) present(ud,vd,ua,va,uin,vin,ieu,inv,iwu,isv,ieeu,innv,wtur,wtvr)
    do k = 1,kn
      do concurrent (iq = 1:ifull)  
        uin(iq,k)=ud(iq,k)+wtur(iq,k,1)*ua(ieu(iq),k)+wtur(iq,k,2)*ua(iwu(iq),k)+wtur(iq,k,3)*ua(ieeu(iq),k)
        vin(iq,k)=vd(iq,k)+wtvr(iq,k,1)*va(inv(iq),k)+wtvr(iq,k,2)*va(isv(iq),k)+wtvr(iq,k,3)*va(innv(iq),k)
      end do  
    end do
    !!$acc end parallel loop
    !!$acc parallel loop collapse(2) present(ud,vd,ua,va,uin,vin,ieu,inv,iwu,isv,ieeu,innv,wtur,wtvr)
    do k = kn+1,kx
      do concurrent (iq = 1:ifull)  
        uin(iq,k)=ud(iq,k)+wtur(iq,1,1)*ua(ieu(iq),k)+wtur(iq,1,2)*ua(iwu(iq),k)+wtur(iq,1,3)*ua(ieeu(iq),k)
        vin(iq,k)=vd(iq,k)+wtvr(iq,1,1)*va(inv(iq),k)+wtvr(iq,1,2)*va(isv(iq),k)+wtvr(iq,1,3)*va(innv(iq),k)
      end do  
    end do
    !!$acc end parallel loop
    !!$acc update self(uin(1:ifull,:),vin(1:ifull,:))
    call boundsuv(uin,vin,stag=2)
    !!$acc update device(uin(ifull+1:ifull+iextra,:),vin(ifull+1:ifull+iextra,:))
    !!$acc parallel loop collapse(2) present(ud,vd,ua,va,uin,vin,ieu,inv,iwu,isv,ieeu,innv,wtur,wtvr)
    do k = 1,kn
      do concurrent (iq = 1:ifull)  
        ua(iq,k)=ud(iq,k)+wtur(iq,k,1)*uin(ieu(iq),k)+wtur(iq,k,2)*uin(iwu(iq),k)+wtur(iq,k,3)*uin(ieeu(iq),k)
        va(iq,k)=vd(iq,k)+wtvr(iq,k,1)*vin(inv(iq),k)+wtvr(iq,k,2)*vin(isv(iq),k)+wtvr(iq,k,3)*vin(innv(iq),k)
      end do  
    end do
    !!$acc end parallel loop
    !!$acc parallel loop collapse(2) present(ud,vd,ua,va,uin,vin,ieu,inv,iwu,isv,ieeu,innv,wtur,wtvr)
    do k = kn+1,kx
      do concurrent (iq = 1:ifull)  
        ua(iq,k)=ud(iq,k)+wtur(iq,1,1)*uin(ieu(iq),k)+wtur(iq,1,2)*uin(iwu(iq),k)+wtur(iq,1,3)*uin(ieeu(iq),k)
        va(iq,k)=vd(iq,k)+wtvr(iq,1,1)*vin(inv(iq),k)+wtvr(iq,1,2)*vin(isv(iq),k)+wtvr(iq,1,3)*vin(innv(iq),k)
      end do  
    end do
    !!$acc end parallel loop
    !!$acc update self(ua(1:ifull,:),va(1:ifull,:))
  end do                  ! itn=1,itnmax

  !!$acc end data

end if

do k = 1,kn
  uout(1:ifull,k)=ua(1:ifull,k)*ee(1:ifull,k)
  vout(1:ifull,k)=va(1:ifull,k)*ee(1:ifull,k)
end do
do k = kn+1,kx
  uout(1:ifull,k)=ua(1:ifull,k)*ee(1:ifull,1)
  vout(1:ifull,k)=va(1:ifull,k)*ee(1:ifull,1)
end do

call END_LOG(ocnstag_end)

return
end subroutine mlounstaguv

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! This subroutine performs vertical advection based on JLMs TVD scheme

subroutine mlovadv(dtin,ww,uu,vv,ss,tt,mm,depdum,idzdum,wtr,cnum)

use cc_mpi
use cc_omp
use mlo
use newmpar_m

implicit none

integer, intent(in) :: cnum
integer ii,iq,its_g,js,je,tile
integer, dimension(imax) :: its
real, intent(in) :: dtin
real, dimension(imax) :: dtnew
real, dimension(ifull,0:wlev), intent(in) :: ww
real, dimension(ifull,wlev), intent(in) :: depdum,idzdum
real, dimension(:,:), intent(inout) :: uu,vv,ss,tt,mm
real, dimension(imax,0:wlev) :: ww_l
real, dimension(imax,wlev) :: dat_l, depdum_l, dzdum
logical, dimension(ifull+iextra,wlev), intent(in) :: wtr

call START_LOG(watervadv_begin)

!$omp parallel private(tile,iq,ii,its,js,je,its_g,ww_l,dzdum,depdum_l,dtnew,dat_l)
!$omp do
do tile = 1,ntiles
  js = (tile-1)*imax + 1
  je = tile*imax

  dzdum    = max(idzdum(js:je,:),1.E-10)
  ww_l     = ww(js:je,:)
  depdum_l = depdum(js:je,:)
  
  ! reduce time step to ensure stability
  dtnew(:)=dtin
  do iq = 1,imax
    do ii = 1,wlev-1
      if ( wtr(iq+js-1,ii) ) then
        ! this trick works if dzdum(iq,ii)<dzdum(iq,ii+1)
        dtnew(iq)=min(dtnew(iq),0.3*dzdum(iq,ii)/max(abs(ww_l(iq,ii)),1.E-12))
      end if
    end do
  end do
  its(1:imax)=int(dtin/(dtnew(:)+0.01))+1
  its_g=maxval(its(:))
  if (its_g>500) then
    write(6,*) "MLOVERT myid,cnum,its_g",myid,cnum,its_g
  end if
  dtnew(:)=dtin/real(its(:))

  dat_l = uu(js:je,:)
  call mlotvd(its,dtnew,ww_l,dat_l,depdum_l,dzdum)
  uu(js:je,:) = dat_l
  dat_l = vv(js:je,:)
  call mlotvd(its,dtnew,ww_l,dat_l,depdum_l,dzdum)
  vv(js:je,:) = dat_l
  dat_l = ss(js:je,:)-34.72
  call mlotvd(its,dtnew,ww_l,dat_l,depdum_l,dzdum)
  ss(js:je,:)=max(dat_l+34.72,0.)
  dat_l = tt(js:je,:)
  call mlotvd(its,dtnew,ww_l,dat_l,depdum_l,dzdum)
  tt(js:je,:)=max(dat_l,-wrtemp)
  dat_l = mm(js:je,:)
  call mlotvd(its,dtnew,ww_l,dat_l,depdum_l,dzdum)
  mm(js:je,:) = dat_l
  
end do
!$omp end do
!$omp end parallel

call END_LOG(watervadv_end)

return
end subroutine mlovadv

pure subroutine mlotvd(its,dtnew,ww,uu,depadj,dzadj)

use mlo
use newmpar_m

implicit none

integer ii,i,iq,kp,kx,ifin
integer, dimension(:), intent(in) :: its
real, dimension(:), intent(in) :: dtnew
real, dimension(:,0:), intent(in) :: ww
real, dimension(:,:), intent(in) :: depadj,dzadj
real, dimension(:,:), intent(inout) :: uu
real, dimension(size(its,1),0:wlev) :: ff
real, dimension(size(its,1),0:wlev) :: delu
real, dimension(size(its,1)) :: fl,fh,cc,rr

! f=(w*u) at half levels
! du/dt = u*dw/dz-df/dz = -w*du/dz

ifin = size(its,1)

delu(1:ifin,0) = 0.
do ii = 1,wlev-1
  delu(1:ifin,ii) = uu(1:ifin,ii+1) - uu(1:ifin,ii)
end do
delu(1:ifin,wlev) = 0.

ff(:,0) = 0.
ff(:,wlev) = 0.

! TVD part
do ii = 1,wlev-1
  ! +ve ww is downwards to the ocean floor
  where ( ww(1:ifin,ii)>0.)
    rr(1:ifin) = delu(1:ifin,ii-1)/(delu(1:ifin,ii)+sign(1.e-20,delu(1:ifin,ii)))
    fl(1:ifin) = ww(1:ifin,ii)*uu(1:ifin,ii)
  elsewhere
    rr(1:ifin) = delu(1:ifin,ii+1)/(delu(1:ifin,ii)+sign(1.e-20,delu(1:ifin,ii)))  
    fl(1:ifin) = ww(1:ifin,ii)*uu(1:ifin,ii+1)
  end where
  cc(1:ifin) = max(0.,min(1.,2.*rr(1:ifin)),min(2.,rr(1:ifin))) ! superbee
  fh(1:ifin) = ww(1:ifin,ii)*0.5*(uu(1:ifin,ii)+uu(1:ifin,ii+1))         &
    - 0.5*(uu(1:ifin,ii+1)-uu(1:ifin,ii))*ww(1:ifin,ii)**2*dtnew(1:ifin) &
   /max(depadj(1:ifin,ii+1)-depadj(1:ifin,ii),1.E-10)
  ff(1:ifin,ii) = fl(1:ifin) + cc(1:ifin)*(fh(1:ifin)-fl(1:ifin))
  !ff(:,ii)=ww(:,ii)*0.5*(uu(1:ifin,ii)+uu(1:ifin,ii+1)) ! explicit
end do
do ii = 1,wlev
  where ( dzadj(1:ifin,ii)>1.e-4 )  
    uu(1:ifin,ii)=uu(1:ifin,ii)+dtnew*(uu(1:ifin,ii)*(ww(1:ifin,ii)-ww(1:ifin,ii-1))   &
                                        -ff(1:ifin,ii)+ff(1:ifin,ii-1))/dzadj(1:ifin,ii)
  end where  
end do


do iq=1,ifin
  do i=2,its(iq)

    do ii=1,wlev-1
      delu(iq,ii)=uu(iq,ii+1)-uu(iq,ii)
    end do

    ! TVD part
    do ii=1,wlev-1
      ! +ve ww is downwards to the ocean floor
      kp = nint(sign(1.,ww(iq,ii)))
      kx = ii+(1-kp)/2 !  k for ww +ve,  k+1 for ww -ve
      rr(iq)=delu(iq,ii-kp)/(delu(iq,ii)+sign(1.E-20,delu(iq,ii)))
      fl(iq)=ww(iq,ii)*uu(iq,kx)
      cc(iq)=max(0.,min(1.,2.*rr(iq)),min(2.,rr(iq))) ! superbee
      fh(iq)=ww(iq,ii)*0.5*(uu(iq,ii)+uu(iq,ii+1))          &
        -0.5*(uu(iq,ii+1)-uu(iq,ii))*ww(iq,ii)**2*dtnew(iq) &
        /max(depadj(iq,ii+1)-depadj(iq,ii),1.E-10)
      ff(iq,ii)=fl(iq)+cc(iq)*(fh(iq)-fl(iq))
    end do
    do ii=1,wlev
      if ( dzadj(iq,ii)>1.e-4 ) then  
        uu(iq,ii)=uu(iq,ii)+dtnew(iq)*(uu(iq,ii)*(ww(iq,ii)-ww(iq,ii-1))-ff(iq,ii)+ff(iq,ii-1))/dzadj(iq,ii)
      end if  
    end do

  end do
end do

return
end subroutine mlotvd

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Use potential temperature and salinity Jacobians to calculate
! density Jacobian

subroutine tsjacobi(nti,nsi,pice,drhobardxu,drhobardyu,drhobardxv,drhobardyv, &
                    rhobar,rhobaru,rhobarv)

use indices_m
use mlo, only : wlev, wrtemp, mloexpdensity
use newmpar_m

implicit none

integer ii
real, dimension(ifull+iextra,wlev), intent(in) :: nti, nsi
real, dimension(ifull,wlev), intent(out) :: drhobardxu, drhobardyu, drhobardxv, drhobardyv
real, dimension(ifull,wlev), intent(out) :: rhobaru, rhobarv, rhobar
real, dimension(ifull+iextra), intent(in) :: pice
real, dimension(ifull+iextra,wlev,2) :: na
real, dimension(ifull+iextra,wlev) :: alpha, beta, lrho, dzdum_rho
real, dimension(ifull) :: absu, bbsu, absv, bbsv
real, dimension(ifull) :: alpha_n, alpha_e, beta_n, beta_e, lrho_e, lrho_n
real, dimension(ifull,wlev,2) :: dnadxu, dnadxv, dnadyu, dnadyv

do ii = 1,wlev
  ! neglect neta for calculating density  
  dzdum_rho(1:ifull+iextra,ii) = godsig(1:ifull+iextra,ii)*dd(1:ifull+iextra)
end do
call mloexpdensity(lrho,alpha,beta,nti,nsi,dzdum_rho,pice,0,rawrho=.true.)

na(:,:,1) = min(max(271.-wrtemp,nti),373.-wrtemp)
na(:,:,2) = min(max(0.,  nsi),50. )-34.72

if ( mlojacobi==0 ) then !off
  do ii = 1,wlev
    drhobardxu(1:ifull,ii) = 0.
    drhobardxv(1:ifull,ii) = 0.
    drhobardyu(1:ifull,ii) = 0.
    drhobardyv(1:ifull,ii) = 0.
    rhobar(:,ii) = 0.
    rhobaru(:,ii) = 0.
    rhobarv(:,ii) = 0.
  end do
else
  select case( mlojacobi )
    case(1,2) ! non-local - spline  
      call seekdelta(na,dnadxu,dnadyu,dnadxv,dnadyv)
    case(6,7) ! z* - 2nd order
      call zstar2(na,dnadxu,dnadyu,dnadxv,dnadyv)  
    case default
      write(6,*) "ERROR: unknown mlojacobi option ",mlojacobi
      stop
  end select  
  do ii = 1,wlev
    call unpack_ne(alpha(:,ii),alpha_n,alpha_e)  
    call unpack_ne(beta(:,ii),beta_n,beta_e)
    absu = 0.5*(alpha(1:ifull,ii)+alpha_e)*eeu(1:ifull,ii)
    bbsu = 0.5*(beta(1:ifull,ii) +beta_e )*eeu(1:ifull,ii)
    absv = 0.5*(alpha(1:ifull,ii)+alpha_n)*eev(1:ifull,ii)
    bbsv = 0.5*(beta(1:ifull,ii) +beta_n )*eev(1:ifull,ii)

    ! This relationship neglects compression effects due to neta from the EOS.
    drhobardxu(1:ifull,ii) = -absu*dnadxu(1:ifull,ii,1) + bbsu*dnadxu(1:ifull,ii,2)
    drhobardxv(1:ifull,ii) = -absv*dnadxv(1:ifull,ii,1) + bbsv*dnadxv(1:ifull,ii,2)
    drhobardyu(1:ifull,ii) = -absu*dnadyu(1:ifull,ii,1) + bbsu*dnadyu(1:ifull,ii,2)
    drhobardyv(1:ifull,ii) = -absv*dnadyv(1:ifull,ii,1) + bbsv*dnadyv(1:ifull,ii,2)
  end do

  ! integrate density gradient  
  drhobardxu(:,1) = drhobardxu(:,1)*godsigu(1:ifull,1)
  drhobardxv(:,1) = drhobardxv(:,1)*godsigv(1:ifull,1)
  drhobardyu(:,1) = drhobardyu(:,1)*godsigu(1:ifull,1)
  drhobardyv(:,1) = drhobardyv(:,1)*godsigv(1:ifull,1)
  call unpack_ne(lrho(:,1),lrho_n,lrho_e)
  rhobar(:,1) = lrho(1:ifull,1)*godsig(1:ifull,1)
  rhobaru(:,1) = 0.5*(lrho(1:ifull,1)+lrho_e)*godsigu(1:ifull,1)
  rhobarv(:,1) = 0.5*(lrho(1:ifull,1)+lrho_n)*godsigu(1:ifull,1)
  do ii = 2,wlev
    drhobardxu(:,ii) = drhobardxu(:,ii-1) + drhobardxu(:,ii)*godsigu(1:ifull,ii)
    drhobardxv(:,ii) = drhobardxv(:,ii-1) + drhobardxv(:,ii)*godsigv(1:ifull,ii)
    drhobardyu(:,ii) = drhobardyu(:,ii-1) + drhobardyu(:,ii)*godsigu(1:ifull,ii)
    drhobardyv(:,ii) = drhobardyv(:,ii-1) + drhobardyv(:,ii)*godsigv(1:ifull,ii)
    call unpack_ne(lrho(:,ii),lrho_n,lrho_e)
    rhobar(:,ii) = rhobar(:,ii-1) + lrho(1:ifull,ii)*godsig(1:ifull,ii)
    rhobaru(:,ii) = rhobaru(:,ii-1) + 0.5*(lrho(1:ifull,ii)+lrho_e)*godsigu(1:ifull,ii)
    rhobarv(:,ii) = rhobarv(:,ii-1) + 0.5*(lrho(1:ifull,ii)+lrho_n)*godsigu(1:ifull,ii)
  end do
  do ii = 1,wlev
    drhobardxu(:,ii) = drhobardxu(:,ii)/gosighu(:,ii)
    drhobardxv(:,ii) = drhobardxv(:,ii)/gosighv(:,ii)
    drhobardyu(:,ii) = drhobardyu(:,ii)/gosighu(:,ii)
    drhobardyv(:,ii) = drhobardyv(:,ii)/gosighv(:,ii)
    rhobar(:,ii) = rhobar(:,ii)/gosigh(:,ii)
    rhobaru(:,ii) = rhobaru(:,ii)/gosighu(:,ii)
    rhobarv(:,ii) = rhobarv(:,ii)/gosighv(:,ii)
  end do
end if
  
return
end subroutine tsjacobi

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Calculate gradients using an interpolation method - spline

subroutine seekdelta(rho,drhodxu,drhodyu,drhodxv,drhodyv)

use indices_m
use map_m
use mlo, only : wlev
use newmpar_m
use parm_m

implicit none

integer ii, jj, iq
real, dimension(ifull,wlev) :: ddux,ddvy
real, dimension(ifull,wlev) :: ddi,dde,ddw,ddn,dds,dden,ddes,ddne,ddnw
real, dimension(ifull,wlev) :: ramp_a,ramp_c
real, dimension(ifull+iextra,wlev) :: dd_i
real, dimension(ifull,wlev,2) :: ri,re,rw,rn,rs,ren,res,rne,rnw
real, dimension(ifull,wlev,2) :: ssi,sse,ssw,ssn,sss,ssen,sses,ssne,ssnw
real, dimension(ifull,wlev,2) :: y2i,y2e,y2w,y2n,y2s,y2en,y2es,y2ne,y2nw
real, dimension(ifull+iextra,wlev,2) :: y2_i
real, dimension(ifull+iextra,wlev,2), intent (in) :: rho
real, dimension(ifull,wlev,2), intent(out) :: drhodxu,drhodyu,drhodxv,drhodyv

! Here we calculate the slow contribution of the pressure gradient

! dP/dx = g rhobar dneta/dx + g sigma D drhobar/dx + g sigma neta drhobar/dx
!                   (fast)               (slow)          (mixed)

! rhobar = int_0^sigma rho dsigma / sigma

! MJT notes - this version fades out extrapolated gradients using ramp_a, etc.
!
! Idealy, we want to separate the neta contribution to drhobar/dx so that it
! can be included in the implicit solution to neta.


do ii = 1,wlev
  dd_i(:,ii) = gosig(:,ii)*dd(:)
  ddux(:,ii) = 0.5*(gosig(1:ifull,ii)+gosig(ie,ii))*ddu(1:ifull)
  ddvy(:,ii) = 0.5*(gosig(1:ifull,ii)+gosig(in,ii))*ddv(1:ifull)
end do
call mlospline(dd_i,rho,y2_i) ! cubic spline

do jj = 1,2
  do ii = 1,wlev
    ssi(:,ii,jj)=rho(1:ifull,ii,jj)
    call unpack_ne(rho(:,ii,jj),ssn(:,ii,jj),sse(:,ii,jj))
    y2i(:,ii,jj)=y2_i(1:ifull,ii,jj)
    call unpack_ne(y2_i(:,ii,jj),y2n(:,ii,jj),y2e(:,ii,jj))
  end do
end do  
do ii = 1,wlev
  ddi(:,ii)  =dd_i(1:ifull,ii)
  call unpack_ne(dd_i(:,ii),ddn(:,ii),dde(:,ii))
end do  

do jj = 1,2
  do ii = 1,wlev
    do iq = 1,ifull  
      sss(iq,ii,jj) =rho(is(iq),ii,jj)
      ssen(iq,ii,jj)=rho(ien(iq),ii,jj)
      sses(iq,ii,jj)=rho(ies(iq),ii,jj)
      y2s(iq,ii,jj) =y2_i(is(iq),ii,jj)
      y2en(iq,ii,jj)=y2_i(ien(iq),ii,jj)
      y2es(iq,ii,jj)=y2_i(ies(iq),ii,jj)
    end do  
  end do
end do  
do ii = 1,wlev
  do iq = 1,ifull
    dds(iq,ii)   =dd_i(is(iq),ii)
    dden(iq,ii)  =dd_i(ien(iq),ii)
    ddes(iq,ii)  =dd_i(ies(iq),ii)
  end do  
end do  

! process staggered u locations
ramp_a(:,:) = 1.
call seekval(ri,ssi,ddi,ddux,y2i,ramp_a)
call seekval(re,sse,dde,ddux,y2e,ramp_a)
do jj = 1,2
  do ii = 1,wlev
    drhodxu(:,ii,jj) = ramp_a(:,ii)*(re(:,ii,jj)-ri(:,ii,jj))*eeu(1:ifull,ii)*emu(1:ifull)/ds
  end do
end do
ramp_c(:,:) = 1.
call seekval(rn, ssn, ddn, ddux,y2n, ramp_c)
call seekval(ren,ssen,dden,ddux,y2en,ramp_c)
call seekval(rs, sss, dds, ddux,y2s, ramp_c)
call seekval(res,sses,ddes,ddux,y2es,ramp_c)
do jj = 1,2
  do ii = 1,wlev
    drhodyu(:,ii,jj) = ramp_a(:,ii)*ramp_c(:,ii)*(0.25*stwgt(1:ifull,ii)*(rn(:,ii,jj)+ren(:,ii,jj) &
                      -rs(:,ii,jj)-res(:,ii,jj))*emu(1:ifull)/ds)
  end do
end do

do jj = 1,2
  do ii = 1,wlev
    do iq = 1,ifull  
      ssw(iq,ii,jj) =rho(iw(iq),ii,jj)
      ssne(iq,ii,jj)=rho(ine(iq),ii,jj)
      ssnw(iq,ii,jj)=rho(inw(iq),ii,jj)
      y2w(iq,ii,jj) =y2_i(iw(iq),ii,jj)
      y2ne(iq,ii,jj)=y2_i(ine(iq),ii,jj)
      y2nw(iq,ii,jj)=y2_i(inw(iq),ii,jj)
    end do
  end do
end do 
do ii = 1,wlev
  do iq = 1,ifull  
    ddw(iq,ii) =dd_i(iw(iq),ii)
    ddne(iq,ii)=dd_i(ine(iq),ii)
    ddnw(iq,ii)=dd_i(inw(iq),ii)
  end do
end do  

! now process staggered v locations
ramp_a(:,:) = 1.
call seekval(ri,ssi,ddi,ddvy,y2i,ramp_a)
call seekval(rn,ssn,ddn,ddvy,y2n,ramp_a)
do jj = 1,2
  do ii =1,wlev
    drhodyv(:,ii,jj) = ramp_a(:,ii)*(rn(:,ii,jj)-ri(:,ii,jj))*eev(1:ifull,ii)*emv(1:ifull)/ds
  end do
end do
ramp_c(:,:) = 1.
call seekval(re, sse, dde, ddvy,y2e, ramp_c)
call seekval(rne,ssne,ddne,ddvy,y2ne,ramp_c)
call seekval(rw, ssw, ddw, ddvy,y2w, ramp_c)
call seekval(rnw,ssnw,ddnw,ddvy,y2nw,ramp_c)
do jj = 1,2
  do ii = 1,wlev
    drhodxv(:,ii,jj) = ramp_a(:,ii)*ramp_c(:,ii)*(0.25*stwgt(1:ifull,ii)*(re(:,ii,jj)+rne(:,ii,jj)   &
                        -rw(:,ii,jj)-rnw(:,ii,jj))*emv(1:ifull)/ds)
  end do
end do

return
end subroutine seekdelta

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Interpolate to common depths - spline

pure subroutine seekval(rout,ssin,ddin,ddseek,y2,ramp)

use cc_mpi
use mlo, only : wlev
use newmpar_m

implicit none

integer iq, ii, jj, ii_min, ii_max
integer, dimension(1) :: pos
integer, dimension(ifull,wlev) :: sindx
real, dimension(ifull,wlev), intent(in) :: ddseek
real, dimension(ifull,wlev), intent(in) :: ddin
real, dimension(ifull,wlev), intent(inout) :: ramp
real, dimension(ifull,wlev,2), intent(in) :: ssin, y2
real, dimension(ifull,wlev,2), intent(out) :: rout
real, dimension(ifull,2) :: ssunpack1, ssunpack0, y2unpack1, y2unpack0
real, dimension(ifull) :: ddunpack1, ddunpack0
real, dimension(ifull) :: h, a, b, tempa, tempb, temph
real, parameter :: dzramp = 0.01 ! extrapolation limit

sindx(:,:) = wlev
do iq = 1,ifull
  ii = 2
  do jj = 1,wlev
    if ( ddseek(iq,jj)<ddin(iq,wlev-1) .and. ii<wlev ) then
      pos = minloc( ddin(iq,ii:wlev-1), ddseek(iq,jj)<ddin(iq,ii:wlev-1) )
      sindx(iq,jj) = pos(1) + ii - 1
      ii = sindx(iq,jj)
    else
      exit
    end if
  end do
end do
  
do  jj = 1,wlev
  ! MJT notes - This calculation is slow
  ii_min = minval( sindx(:,jj) )
  ii_max = maxval( sindx(:,jj) )
  do ii = ii_min,ii_max
    where ( ii==sindx(:,jj) )
      ddunpack1(:) = ddin(:,ii)
      ddunpack0(:) = ddin(:,ii-1)
      ssunpack1(:,1) = ssin(:,ii,1)
      ssunpack1(:,2) = ssin(:,ii,2)
      ssunpack0(:,1) = ssin(:,ii-1,1)
      ssunpack0(:,2) = ssin(:,ii-1,2)
      y2unpack1(:,1) = y2(:,ii,1)
      y2unpack1(:,2) = y2(:,ii,2)
      y2unpack0(:,1) = y2(:,ii-1,1)    
      y2unpack0(:,2) = y2(:,ii-1,2)    
    end where
  end do

  h(:) = max(ddunpack1(:)-ddunpack0(:), 1.e-8)
  a(:) = (ddunpack1(:)-ddseek(:,jj))/h(:)
  b(:) = 1. - a(:)
  temph(:) = h(:)**2/6.
  tempa(:) = (a(:)**3-a(:))*temph(:)
  tempb(:) = (b(:)**3-b(:))*temph(:)
  
  rout(:,jj,1) = a(:)*ssunpack0(:,1)+b(:)*ssunpack1(:,1)            & ! linear interpolation
                 +tempa(:)*y2unpack0(:,1)+tempb(:)*y2unpack1(:,1)     ! cubic spline terms
  rout(:,jj,2) = a(:)*ssunpack0(:,2)+b(:)*ssunpack1(:,2)            & ! linear interpolation
                 +tempa(:)*y2unpack0(:,2)+tempb(:)*y2unpack1(:,2)     ! cubic spline terms

  ! fade out extrapolation
  ramp(:,jj) = ramp(:,jj)*min(max((a(:)+dzramp)/dzramp,0.),1.)*min(max((b(:)+dzramp)/dzramp,0.),1.)
end do

return
end subroutine seekval

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Calculate coeff for cubic spline

pure subroutine mlospline(x,y,y2)

use mlo, only : wlev
use newmpar_m

implicit none

integer ii, jj
real, dimension(ifull+iextra,wlev), intent(in) :: x
real, dimension(ifull+iextra,wlev,2), intent(in) :: y
real, dimension(ifull+iextra,wlev,2), intent(out) :: y2
real, dimension(ifull+iextra,wlev) :: u
real, dimension(ifull+iextra,wlev) :: sig
real, dimension(ifull+iextra) :: p

do ii = 2,wlev-1
  sig(:,ii) = (x(:,ii)-x(:,ii-1))/max(x(:,ii+1)-x(:,ii-1), 1.e-8)
end do

do jj = 1,2
  y2(:,1,jj) = 0.
  u(:,1) = 0.
  do ii = 2,wlev-1
    p(:) = sig(:,ii)*y2(:,ii-1,jj) + 2.
    y2(:,ii,jj) = (sig(:,ii)-1.)/p(:)
    u(:,ii) = (6.*((y(:,ii+1,jj)-y(:,ii,jj))/max(x(:,ii+1)-x(:,ii),1.e-8)-(y(:,ii,jj)-y(:,ii-1,jj)) &
             /max(x(:,ii)-x(:,ii-1),1.e-8))/max(x(:,ii+1)-x(:,ii-1),1.e-8)-sig(:,ii)*u(:,ii-1))/p(:)
  end do
  y2(:,wlev,jj) = 0.    
  do ii = wlev-1,1,-1
    y2(:,ii,jj) = y2(:,ii,jj)*y2(:,ii+1,jj) + u(:,ii)
  end do
end do

return
end subroutine mlospline

subroutine zstar2(rho,drhodxu,drhodyu,drhodxv,drhodyv)

use indices_m
use map_m
use mlo, only : wlev
use newmpar_m
use parm_m

implicit none

integer ii, jj, iq
real, dimension(ifull) :: ssi,sse,ssw,ssn,sss,ssen,sses,ssne,ssnw
real, dimension(ifull+iextra,wlev,2), intent (in) :: rho
real, dimension(ifull,wlev,2), intent(out) :: drhodxu,drhodyu,drhodxv,drhodyv

! Here we calculate the slow contribution of the pressure gradient

! dP/dx = g rhobar dneta/dx + g sigma D drhobar/dx + g sigma neta drhobar/dx
!                   (fast)               (slow)          (mixed)

! rhobar = int_0^sigma rho dsigma / sigma

do jj = 1,2
  do ii = 1,wlev
    ssi(:) = rho(1:ifull,ii,jj)
    call unpack_nsew(rho(:,ii,jj),ssn(:),sss(:),sse(:),ssw(:))
    do iq = 1,ifull
      ssen(iq) = rho(ien(iq),ii,jj)
      sses(iq) = rho(ies(iq),ii,jj)
      ssne(iq) = rho(ine(iq),ii,jj)
      ssnw(iq) = rho(inw(iq),ii,jj)
    end do  
    ! process staggered u locations  
    drhodxu(:,ii,jj)=(sse(:)-ssi(:))*eeu(1:ifull,ii)*emu(1:ifull)/ds
    drhodyu(:,ii,jj)=0.25*stwgt(1:ifull,ii)*emu(1:ifull)/ds*(ssn(:)-sss(:)+ssen(:)-sses(:))
    ! process staggered v locations
    drhodyv(:,ii,jj)=(ssn(:)-ssi(:))*eev(1:ifull,ii)*emv(1:ifull)/ds
    drhodxv(:,ii,jj)=0.25*stwgt(1:ifull,ii)*emv(1:ifull)/ds*(sse(:)-ssw(:)+ssne(:)-ssnw(:))
  end do
end do

return
end subroutine zstar2


!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Calculate tidal potential

pure subroutine mlotide(eta,slon,slat,mtimer,jstart)

use newmpar_m

implicit none

integer, intent(in) :: mtimer,jstart
real, dimension(ifull), intent(out) :: eta
real, dimension(ifull), intent(in) :: slon,slat
real ltime,stime,ctime,mn,sn,pn
real, dimension(ifull) :: sinlat,coslat
real, dimension(4) :: aa,ab,ba,bb
real, parameter :: pi = 3.14159265

! amplitude (mom3)
aa(1)=0.141565 ! K1
aa(2)=0.100661 ! O1
aa(3)=0.046848 ! P1
aa(4)=0.019273 ! Q1
ab(1)=0.242334 ! M2
ab(2)=0.112743 ! S2
ab(3)=0.046397 ! N2
ab(4)=0.030684 ! K2
! Love number (mom3)
ba(1)=0.736
ba(2)=0.695
ba(3)=0.706
ba(4)=0.695
bb(1)=0.693
bb(2)=0.693
bb(3)=0.693
bb(4)=0.693
! Frequency (mom3)
!wa(1)=0.7292117
!wa(2)=0.6750774
!wa(3)=0.7252295
!wa(4)=0.6495854
!wb(1)=1.405189
!wb(2)=1.454441 ! exactly twice per day solar day for S2
!wb(3)=1.378797
!wb(4)=1.458423

stime=real(mtimer)/1440.+real(jstart) ! solar time (days)
ctime=stime/36525. ! century (relative to 12Z 31 Dec 1899)

mn=270.43659+481276.89057*ctime+0.00198*ctime*ctime+0.000002*ctime*ctime*ctime ! moon
sn=279.69668+36000.76892*ctime+0.00030*ctime*ctime                             ! sun
pn=334.32956+4069.03404*ctime-0.01032*ctime*ctime-0.00001*ctime*ctime*ctime    ! lunar perigee
mn=mn*pi/180.
sn=sn*pi/180.
pn=pn*pi/180.
stime=(stime-real(int(stime)))*2.*pi ! solar time (rad)
ltime=stime+sn-mn                    ! lunar time (rad)
! 360*stime=360*ltime-9.3+12.2*day

coslat=cos(slat)**2
sinlat=sin(2.*slat)

eta=ba(1)*aa(1)*sinlat*cos(ltime+mn-slon)          &    ! K1 (note sign change)
   -ba(2)*aa(2)*sinlat*cos(ltime-mn-slon)          &    ! O1
   -ba(3)*aa(3)*sinlat*cos(stime-sn-slon)          &    ! P1
   -ba(4)*aa(4)*sinlat*cos(ltime+pn-slon)          &    ! Q1
   -bb(1)*ab(1)*coslat*cos(2.*ltime-2.*slon)       &    ! M2
   -bb(2)*ab(2)*coslat*cos(2.*stime-2.*slon)       &    ! S2
   -bb(3)*ab(3)*coslat*cos(2.*ltime-mn+pn-2.*slon) &    ! N2
   -bb(4)*ab(4)*coslat*cos(2.*stime+2.*sn-2.*slon)      ! K2

!sinlon=sin(2.*slon)
!coslon=cos(2.*slon)
!eta=0.
!do i=1,4
!  eta=eta-ba(i)*aa(i)*coslat*(cos(wa(i)*stime)*coslon-sin(wa(i)*stime)*sinlon)
!  eta=eta-bb(i)*ab(i)*sinlat*(cos(wb(i)*stime)*coslon-sin(wb(i)*stime)*sinlon)
!end do

return
end subroutine mlotide

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! test for leap year

pure subroutine mloleap(tyear,ttest)

implicit none

integer, intent(in) :: tyear
logical, intent(out) :: ttest

ttest=.false.
if (mod(tyear,4)==0)   ttest=.true.
if (mod(tyear,100)==0) ttest=.false.
if (mod(tyear,400)==0) ttest=.true.

return
end subroutine mloleap

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Calculate local sum

subroutine mlosum(datain,sumout)

implicit none

integer i
real e, t1, t2
real, dimension(:), intent(in) :: datain
complex, intent(out) :: sumout

sumout = (0., 0.)
do i = 1,size(datain)
  t1 = datain(i) + real(sumout)
  e = t1 - datain(i)
  t2 = ((real(sumout) - e) + (datain(i) - (t1 - e))) + aimag(sumout)
  sumout = cmplx( t1 + t2, t2 - ((t1 + t2) - t1) )
end do

return
end subroutine mlosum
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Advect sea-ice using simple upwind scheme

subroutine upwind_iceadv(dumc,niu,niv,spnet)

use indices_m
use map_m
use newmpar_m
use parm_m

implicit none

real, dimension(ifull+iextra), intent(inout) :: dumc
real, dimension(ifull+iextra), intent(in) :: niu,niv,spnet
real(kind=8), dimension(ifull) :: odum,dumd,tdum
real, dimension(ifull) :: spnet_n, spnet_s, spnet_e, spnet_w
real, dimension(ifull) :: dumc_n, dumc_s, dumc_e, dumc_w
real, dimension(ifull) :: em_isv, em_iwu, ni_isv, ni_iwu

dumd=dumc(1:ifull)
call unpack_nsew(spnet,spnet_n,spnet_s,spnet_e,spnet_w)
call unpack_nsew(dumc,dumc_n,dumc_s,dumc_e,dumc_w)
call unpack_svwu(niu,niv,ni_isv,ni_iwu)
call unpack_svwu(emu,emv,em_isv,em_iwu)

odum=0.5*dt*(ni_iwu*(dumc(1:ifull)+dumc_w)    -abs(ni_iwu)*(dumc(1:ifull)-dumc_w)    )*emu(iwu)/ds
where ( spnet_w>1.e-10 )
  tdum=dumc_w*max(ni_iwu*em_iwu,0.)/(ds*spnet_w)    
  odum=min(odum,tdum)
elsewhere
  odum=min(odum,0._8)
end where
where ( spnet(1:ifull)>1.e-10 )
  tdum=dumc(1:ifull)*min(ni_iwu*em_iwu,0.)/(ds*spnet(1:ifull))
  odum=max(odum,tdum)
elsewhere
  odum=max(odum,0._8)
end where
dumd=dumd+odum

odum=-0.5*dt*(niu(1:ifull)*(dumc(1:ifull)+dumc_e)+abs(niu(1:ifull))*(dumc(1:ifull)-dumc_e))*emu(1:ifull)/ds
where ( spnet_e>1.e-10 )
  tdum=-dumc_e*min(niu(1:ifull)*emu(1:ifull),0.)/(ds*spnet_e)
  odum=min(odum,tdum)
elsewhere
  odum=min(odum,0._8)
end where
where ( spnet(1:ifull)>1.e-10 )
  tdum=-dumc(1:ifull)*max(niu(1:ifull)*emu(1:ifull),0.)/(ds*spnet(1:ifull))
  odum=max(odum,tdum)
elsewhere
  odum=max(odum,0._8)
end where
dumd=dumd+odum  

odum=0.5*dt*(ni_isv*(dumc(1:ifull)+dumc_s)    -abs(ni_isv)*(dumc(1:ifull)-dumc_s)    )*emv(isv)/ds
where ( spnet_s>1.e-10 )
  tdum=dumc_s*max(ni_isv*em_isv,0.)/(ds*spnet_s)
  odum=min(odum,tdum)
elsewhere
  odum=min(odum,0._8)
end where
where ( spnet(1:ifull)>1.e-10 )
  tdum=dumc(1:ifull)*min(ni_isv*em_isv,0.)/(ds*spnet(1:ifull))
  odum=max(odum,tdum)
elsewhere
  odum=max(odum,0._8)
end where
dumd=dumd+odum

odum=-0.5*dt*(niv(1:ifull)*(dumc(1:ifull)+dumc_n)+abs(niv(1:ifull))*(dumc(1:ifull)-dumc_n))*emv(1:ifull)/ds
where ( spnet_n>1.e-10 )
  tdum=-dumc_n*min(niv(1:ifull)*emv(1:ifull),0.)/(ds*spnet_n)    
  odum=min(odum,tdum)
elsewhere
  odum=min(odum,0._8)
end where
where ( spnet(1:ifull)>1.e-10 )
  tdum=-dumc(1:ifull)*max(niv(1:ifull)*emv(1:ifull),0.)/(ds*spnet(1:ifull))
  odum=max(odum,tdum)
elsewhere
  odum=max(odum,0._8)
end where
dumd=dumd+odum

dumc(1:ifull)=real(max(dumd,0._8))
  
return
end subroutine upwind_iceadv

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Use multi-grid to solve for free surface and ice pressure

subroutine mlomg(neta,sou,sov,snu,snv,xps,bb,bb3u,bb4v,ipice,niu,niv,ibb,ibb3u,ibb4v, &
                 ipmax,totits,maxglobseta,maxglobip)

use helmsolve
use indices_m
use map_m
use newmpar_m
use parm_m

implicit none

integer, intent(out) :: totits
real, intent(out) :: maxglobseta, maxglobip
real, dimension(ifull), intent(in) :: xps
real, dimension(ifull+iextra), intent(inout) :: neta, ipice
real, dimension(ifull+iextra), intent(in) :: ipmax
real, dimension(ifull+iextra), intent(in) :: sou, sov, snu, snv
real, dimension(ifull+iextra), intent(in) :: bb, bb3u, bb4v
real, dimension(ifull+iextra), intent(in) :: niu, niv
real, dimension(ifull+iextra), intent(in) :: ibb, ibb3u, ibb4v
real, dimension(ifull,2) :: zz, zzn, zzs, zze, zzw, rhs
real, dimension(ifull) :: odiv_d, odiv_n
real, dimension(ifull) :: hh, ff, ddddx, ddddy
real, dimension(ifull) :: yy, yyn, yys, yye, yyw
real, dimension(ifull) :: so_isv, so_iwu, sn_isv, sn_iwu
real, dimension(ifull) :: dd_n, dd_s, dd_e, dd_w, dd_iwu, dd_isv
real, dimension(ifull) :: ni_isv, ni_iwu, em_isv, em_iwu
real, dimension(ifull) :: ibb_n, ibb_s, ibb_e, ibb_w, ibb3u_iwu, ibb4v_isv
real, dimension(ifull) :: bb_n, bb_s, bb_e, bb_w, bb3u_iwu, bb4v_isv

call mgsor_init

! ocean

call unpack_nsew(dd,dd_n,dd_s,dd_e,dd_w)
call unpack_svwu(ddu,ddv,dd_isv,dd_iwu)
call unpack_svwu(emu,emv,em_isv,em_iwu)
call unpack_svwu(sou,sov,so_isv,so_iwu)
call unpack_svwu(snu,snv,sn_isv,sn_iwu)
call unpack_nsew(bb,bb_n,bb_s,bb_e,bb_w)
call unpack_svwu(bb3u,bb4v,bb4v_isv,bb3u_iwu)

ff = (1.+ocneps)*0.5*dt*f(1:ifull)
ddddx = (ddu/emu(1:ifull)-dd_iwu/em_iwu)*em(1:ifull)**2/ds
ddddy = (ddv/emv(1:ifull)-dd_isv/em_isv)*em(1:ifull)**2/ds

!sum nu dz = sou + snu*etau + grav*bu*detadxu + grav*ff*bu*detadyu
!sum nv dz = sov + snv*etav + grav*bv*detadyv - grav*ff*bv*detadxv

!sum nu dz = sou + snu*etau + grav*d(b*eta)/dx + grav*d(b*ff*eta)/dy - grav*b3*eta
!sum nv dz = sov + snv*etav + grav*d(b*eta)/dy - grav*d(b*ff*eta)/dy - grav*b4*eta

!ff = (1.+ocneps)*0.5*dt*f
!b = -(1.+ocneps)*0.5*dt/(1.+ff**2)
!b3 = db/dx + d(b*ff)/dy
!b4 = db/dy - d(b*ff)/dx

! div = d(sou)/dx + d(sov)/dy + d(snu*eta)/dx + d(snv*eta)/dy
! + grav*d2(b*eta)/dx2 + grav*d2(b*eta)/dy2 - d(b3u*eta)/dx - d(b4v*eta)/dy

! Lagrangian version of the contunity equation with D included in flux form
!   [neta + (1+eps)*0.5*dt*(neta*(du/dx+dv/dy)+d(D*u)/dx+d(D*v)/dy+dw/dsig)]^(t+1) = xps

! neta + (1+eps)*0.5*dt*( neta*(d(sou)/dx+d(sov)/dy) + d(D*sou)/dx+d(D*sov)/dy)
!                        + neta*(d(snu*eta)/dx+d(snv*eta)/dy) + D*(d(snu*eta)/dx+d(snv*eta)/dy)
!                        + grav*neta*(d2(b*eta)/dx2+d2(b*eta)/dy2) - grav*neta*(d(b3u*eta)/dx+d(b4v*eta)/dy)
!                        + grav*D*(d2(b*eta)/dx2+d2(b*eta)/dy2) - grav*D*(d(b3*eta)/dx+d(b4*eta)/dy)
!                        + grav*(b*d(eta)/dx+ff*b*d(eta)/dy)*dD/dx + grav*(b*d(eta)/dy-ff*b*d(eta)/dx)*dD/dy
! neta + (1+eps)*0.5*dt*( neta*odiv_n + yy*neta*(d2neta/dx2+d2neta/dy2+dneta/dx+dneta/dy)
!                        + odiv_d + zz*(d2neta/dx2+d2neta/dy2+dneta/dx+dneta/dy) ) = xps

! prep ocean gradient terms - constant
odiv_d = (sou(1:ifull)*ddu(1:ifull)/emu(1:ifull)-so_iwu*dd_iwu/em_iwu  &
         +sov(1:ifull)*ddv(1:ifull)/emv(1:ifull)-so_isv*dd_isv/em_isv) &
         *em(1:ifull)**2/ds

odiv_n = (sou(1:ifull)/emu(1:ifull)-so_iwu/em_iwu  &
         +sov(1:ifull)/emv(1:ifull)-so_isv/em_isv) &
         *em(1:ifull)**2/ds

! yy*neta*(d2neta/dx2+d2neta/dy2+dneta/dx+dneta/dy) + zz*(d2neta/dx2+d2neta/dy2+dneta/dx+dneta/dy) + hh*neta = rhs

yyn(:) = (1.+ocneps)*0.5*dt*grav*em(1:ifull)**2/ds*(bb_n/ds-0.5*bb4v(1:ifull)/emv(1:ifull)+0.5*snv(1:ifull)/emv(1:ifull))
yys(:) = (1.+ocneps)*0.5*dt*grav*em(1:ifull)**2/ds*(bb_s/ds+0.5*bb4v_isv/em_isv-0.5*sn_isv/em_isv)
yye(:) = (1.+ocneps)*0.5*dt*grav*em(1:ifull)**2/ds*(bb_e/ds-0.5*bb3u(1:ifull)/emu(1:ifull)+0.5*snu(1:ifull)/emu(1:ifull))
yyw(:) = (1.+ocneps)*0.5*dt*grav*em(1:ifull)**2/ds*(bb_w/ds+0.5*bb3u_iwu/em_iwu-0.5*sn_iwu/em_iwu)
yy(:)  = (1.+ocneps)*0.5*dt*grav*em(1:ifull)**2/ds*(-4.*bb(1:ifull)/ds                                        &
         -0.5*bb4v(1:ifull)/emv(1:ifull)+0.5*snv(1:ifull)/emv(1:ifull)+0.5*bb4v_isv/em_isv-0.5*sn_isv/em_isv  &
         -0.5*bb3u(1:ifull)/emu(1:ifull)+0.5*snu(1:ifull)/emu(1:ifull)+0.5*bb3u_iwu/em_iwu-0.5*sn_iwu/em_iwu)

zzn(:,1) = (1.+ocneps)*0.5*dt*grav*em(1:ifull)**2/ds*(bb_n*dd(1:ifull)/ds-0.5*bb4v(1:ifull)*dd(1:ifull)/emv(1:ifull) &
          +0.5*bb(1:ifull)*ddddy/emv(1:ifull)+0.5*bb(1:ifull)*ff*ddddx/emv(1:ifull)                                  &
          +0.5*snv(1:ifull)*ddv(1:ifull)/emv(1:ifull))
zzs(:,1) = (1.+ocneps)*0.5*dt*grav*em(1:ifull)**2/ds*(bb_s*dd(1:ifull)/ds+0.5*bb4v_isv*dd(1:ifull)/em_isv &
          -0.5*bb(1:ifull)*ddddy/em_isv-0.5*bb(1:ifull)*ff*ddddx/em_isv                                   &
          -0.5*sn_isv*dd_isv/em_isv)
zze(:,1) = (1.+ocneps)*0.5*dt*grav*em(1:ifull)**2/ds*(bb_e*dd(1:ifull)/ds-0.5*bb3u(1:ifull)*dd(1:ifull)/emu(1:ifull) &
          +0.5*bb(1:ifull)*ddddx/emu(1:ifull)-0.5*bb(1:ifull)*ff*ddddy/emu(1:ifull)                                  &
          +0.5*snu(1:ifull)*ddu(1:ifull)/emu(1:ifull))
zzw(:,1) = (1.+ocneps)*0.5*dt*grav*em(1:ifull)**2/ds*(bb_w*dd(1:ifull)/ds+0.5*bb3u_iwu*dd(1:ifull)/em_iwu & 
          -0.5*bb(1:ifull)*ddddx/em_iwu+0.5*bb(1:ifull)*ff*ddddy/em_iwu                                   &
          -0.5*sn_iwu*dd_iwu/em_iwu)
zz(:,1)  = (1.+ocneps)*0.5*dt*grav*em(1:ifull)**2/ds*(-4.*bb(1:ifull)*dd(1:ifull)/ds   &
          -0.5*bb4v(1:ifull)*dd(1:ifull)/emv(1:ifull)+0.5*bb4v_isv*dd(1:ifull)/em_isv  &
          -0.5*bb3u(1:ifull)*dd(1:ifull)/emu(1:ifull)+0.5*bb3u_iwu*dd(1:ifull)/em_iwu  &
          +0.5*bb(1:ifull)*ddddy/emv(1:ifull)+0.5*bb(1:ifull)*ff*ddddx/emv(1:ifull)    &
          -0.5*bb(1:ifull)*ddddy/em_isv-0.5*bb(1:ifull)*ff*ddddx/em_isv                &
          +0.5*bb(1:ifull)*ddddx/emu(1:ifull)-0.5*bb(1:ifull)*ff*ddddy/emu(1:ifull)    &
          -0.5*bb(1:ifull)*ddddx/em_iwu+0.5*bb(1:ifull)*ff*ddddy/em_iwu                &
          +0.5*snv(1:ifull)*ddv(1:ifull)/emu(1:ifull)-0.5*sn_isv*dd_isv/em_isv         &
          +0.5*snu(1:ifull)*ddu(1:ifull)/emv(1:ifull)-0.5*sn_iwu*dd_iwu/em_iwu)

hh(:) = 1. + (1.+ocneps)*0.5*dt*odiv_n

rhs(:,1) = xps(1:ifull) - (1.+ocneps)*0.5*dt*odiv_d


! ice
! zz*(d2ipice/dx2 + d2ipice/dy2) + zz*d2ipice/dxdy = rhs

call unpack_nsew(ibb,ibb_n,ibb_s,ibb_e,ibb_w)
call unpack_svwu(ibb3u,ibb4v,ibb4v_isv,ibb3u_iwu)
call unpack_svwu(niu,niv,ni_isv,ni_iwu)

zzn(:,2) = -ibb_n/ds + 0.5*ibb4v(1:ifull)/emv(1:ifull) 
zzs(:,2) = -ibb_s/ds - 0.5*ibb4v_isv/em_isv
zze(:,2) = -ibb_e/ds + 0.5*ibb3u(1:ifull)/emu(1:ifull)
zzw(:,2) = -ibb_w/ds - 0.5*ibb3u_iwu/em_iwu
zz(:,2)  = 4.*ibb(1:ifull)/ds                                     &
         + 0.5*ibb4v(1:ifull)/emv(1:ifull) - 0.5*ibb4v_isv/em_isv &
         + 0.5*ibb3u(1:ifull)/emu(1:ifull) - 0.5*ibb3u_iwu/em_iwu
rhs(:,2) = min(niu(1:ifull)/emu(1:ifull)-ni_iwu/em_iwu+niv(1:ifull)/emv(1:ifull)-ni_isv/em_isv,0.)

! Ensure that zero is a valid solution for ice free grid points
where ( zz(:,2)>=0. )
  zz(:,2)  = -dt/(ds*100.) ! 100 is the minimum imass
  zzn(:,2) = 0.
  zzs(:,2) = 0.
  zze(:,2) = 0.
  zzw(:,2) = 0.
  rhs(:,2) = 0.
end where

call mgmlo(neta,ipice,yy,yyn,yys,yye,yyw,zz,zzn,zzs,zze,zzw,   &
           hh,rhs,tol,itol,totits,maxglobseta,maxglobip,ipmax, &
           ee(:,1),dd)

return
end subroutine mlomg

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! This subroutine processes horizontal diffusion, based on Griffies (2000)
! and McGregor's hordifg.f routines for CCAM.
subroutine mlodiffusion_work(u,v,tt,ss)

use cc_mpi
use const_phys
use indices_m
use map_m
use mlo
use mlodynamicsarrays_m
use newmpar_m
use parm_m
use soil_m
use vecsuv_m

implicit none

integer iq, k
real hdif
real, dimension(ifull+iextra,wlev,3) :: duma
real, dimension(ifull+iextra,wlev) :: uau,uav
real, dimension(ifull+iextra,wlev) :: xfact,yfact,dep
real, dimension(ifull+iextra,wlev+1) :: t_kh
real, dimension(ifull,wlev), intent(inout) :: u,v,tt,ss
real base
real dudx,dvdx,dudy,dvdy
real nu,nv,nw
real, dimension(ifull) :: emi
real tx_fact, ty_fact

call START_LOG(waterdiff_begin)

if ( abs(nmlo)>=3 ) then
  do k = 1,wlev  
    uau(1:ifull,k) = (av_vmod*u(1:ifull,k)+(1.-av_vmod)*oldu1(1:ifull,k))*ee(1:ifull,k)
    uav(1:ifull,k) = (av_vmod*v(1:ifull,k)+(1.-av_vmod)*oldv1(1:ifull,k))*ee(1:ifull,k)
  end do  
else
  do k = 1,wlev  
    uau(1:ifull,k) = u(1:ifull,k)*ee(1:ifull,k)
    uav(1:ifull,k) = v(1:ifull,k)*ee(1:ifull,k)
  end do
end if
call boundsuv(uau,uav,allvec=.true.)

! Define diffusion scale and grid spacing
hdif = dt*(ocnsmag/pi)**2
emi = dd(1:ifull)/em(1:ifull)

! calculate diffusion following Smagorinsky
do k = 1,wlev
  do concurrent (iq = 1:ifull)
    dudx = 0.5*((uau(ieu(iq),k)-uau(iq,k))*emu(iq)        &
               +(uau(iq,k)-uau(iwu(iq),k))*emu(iwu(iq)))/ds
    dudy = 0.5*((uau(inu(iq),k)-uau(iq,k))*emv(iq)        &
               +(uau(iq,k)-uau(isu(iq),k))*emv(isv(iq)))/ds
    dvdx = 0.5*((uav(iev(iq),k)-uav(iq,k))*emu(iq)        &
               +(uav(iq,k)-uav(iwv(iq),k))*emu(iwu(iq)))/ds
    dvdy = 0.5*((uav(inv(iq),k)-uav(iq,k))*emv(iq)        &
               +(uav(iq,k)-uav(isv(iq),k))*emv(isv(iq)))/ds
    t_kh(iq,k) = sqrt(dudx**2+dvdy**2+0.5*(dudy+dvdx)**2)*hdif*emi(iq)
  end do
end do
call bounds(t_kh(:,1:wlev),nehalf=.true.)


! reduce diffusion errors where bathymetry gradients are steep
if ( mlosigma>=0 .and. mlosigma<=3 ) then
  ! sigma levels  
  do k = 1,wlev
    dep(1:ifull,k) = gosig(1:ifull,k)*dd(1:ifull) !+ gosig(1:ifull,k)*eta(1:ifull)
  end do  
  call bounds(dep,nehalf=.true.)
  do k = 1,wlev
    do concurrent (iq = 1:ifull)
      tx_fact = 1./(1.+(abs(dep(ie(iq),k)-dep(iq,k))/ocndelphi)**nf)
      ty_fact = 1./(1.+(abs(dep(in(iq),k)-dep(iq,k))/ocndelphi)**nf)
      xfact(iq,k) = 0.5*(t_kh(iq,k)+t_kh(ie(iq),k))*tx_fact*eeu(iq,k) ! reduction factor
      yfact(iq,k) = 0.5*(t_kh(iq,k)+t_kh(in(iq),k))*ty_fact*eev(iq,k) ! reduction factor
    end do
  end do
else
  ! z* levels
  do k = 1,wlev
    xfact(1:ifull,k) = 0.5*(t_kh(1:ifull,k)+t_kh(ie,k))*eeu(1:ifull,k)
    yfact(1:ifull,k) = 0.5*(t_kh(1:ifull,k)+t_kh(in,k))*eev(1:ifull,k)
  end do
end if
call boundsuv(xfact,yfact,stag=-9)


if ( mlodiff==0 ) then
  ! Laplacian diffusion terms (closure #1)
  do k = 1,wlev
    duma(1:ifull,k,1) = ax(1:ifull)*u(1:ifull,k) + bx(1:ifull)*v(1:ifull,k)
    duma(1:ifull,k,2) = ay(1:ifull)*u(1:ifull,k) + by(1:ifull)*v(1:ifull,k)
    duma(1:ifull,k,3) = az(1:ifull)*u(1:ifull,k) + bz(1:ifull)*v(1:ifull,k)
  end do
  call bounds(duma(:,:,1:3))
  do k = 1,wlev
    do concurrent (iq = 1:ifull)
      base = emi(iq) + xfact(iq,k) + xfact(iwu(iq),k) &
                     + yfact(iq,k) + yfact(isv(iq),k)
      nu = ( duma(iq,k,1)*emi(iq) +                       &
             xfact(iq,k)*duma(ie(iq),k,1) +               &
             xfact(iwu(iq),k)*duma(iw(iq),k,1) +          &
             yfact(iq,k)*duma(in(iq),k,1) +               &
             yfact(isv(iq),k)*duma(is(iq),k,1) )          &
           / base
      nv = ( duma(iq,k,2)*emi(iq) +                       &
             xfact(iq,k)*duma(ie(iq),k,2) +               &
             xfact(iwu(iq),k)*duma(iw(iq),k,2) +          &
             yfact(iq,k)*duma(in(iq),k,2) +               &
             yfact(isv(iq),k)*duma(is(iq),k,2) )          &
           / base
      nw = ( duma(iq,k,3)*emi(iq) +                       &
             xfact(iq,k)*duma(ie(iq),k,3) +               &
             xfact(iwu(iq),k)*duma(iw(iq),k,3) +          &
             yfact(iq,k)*duma(in(iq),k,3) +               &
             yfact(isv(iq),k)*duma(is(iq),k,3) )          &
           / base
      u(iq,k) = ax(iq)*nu + ay(iq)*nv + az(iq)*nw
      v(iq,k) = bx(iq)*nu + by(iq)*nv + bz(iq)*nw
    end do
  end do

else if ( mlodiff==1 ) then
  ! no diffusion applied to momentum
else
  write(6,*) "ERROR: Unknown option for mlodiff = ",mlodiff
  call ccmpi_abort(-1)
end if

! Potential temperature and salinity
duma(1:ifull,:,1) = tt(1:ifull,:)
duma(1:ifull,:,2) = ss(1:ifull,:) - 34.72
call bounds(duma(:,:,1:2))
!$acc parallel loop collapse(2) copyin(emi,xfact,yfact,iwu,isv,ie,iw,in,is,duma(:,:,1:2)) copyout(tt,ss)
do k = 1,wlev
  do concurrent (iq = 1:ifull)
    base = emi(iq) + xfact(iq,k) + xfact(iwu(iq),k) &
                   + yfact(iq,k) + yfact(isv(iq),k)
    tt(iq,k) = ( duma(iq,k,1)*emi(iq) +               &
                 xfact(iq,k)*duma(ie(iq),k,1) +       &
                 xfact(iwu(iq),k)*duma(iw(iq),k,1) +  &
                 yfact(iq,k)*duma(in(iq),k,1) +       &
                 yfact(isv(iq),k)*duma(is(iq),k,1) )  &
               / base
    tt(iq,k) = max(tt(iq,k), -wrtemp)
    ss(iq,k) = ( duma(iq,k,2)*emi(iq) +               &
                 xfact(iq,k)*duma(ie(iq),k,2) +       &
                 xfact(iwu(iq),k)*duma(iw(iq),k,2) +  &
                 yfact(iq,k)*duma(in(iq),k,2) +       &
                 yfact(isv(iq),k)*duma(is(iq),k,2) )  &
               / base
    ss(iq,k) = max(ss(iq,k)+34.72, 0.)
  end do
end do
!$acc end parallel loop

call END_LOG(waterdiff_end)

return
end subroutine mlodiffusion_work

end module mlodynamics
