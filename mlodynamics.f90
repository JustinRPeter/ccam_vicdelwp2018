! These subroutines handle dynamics for the Mixed-Layer-Ocean model

! - Horizontal diffusion
! - River routing
! - Ocean dynamics
! - Ice dynamics

! This module also links to mlo.f90 which solves for 1D physics of
! ocean and ice processes.  Currently the code assumes the hydrostatic
! approximation which is reasonably valid to 1km resolution.

! Ocean and sea-ice dynamics are based on the R-grid used by CCAM

module mlodynamics

implicit none

private
public mlodiffusion,mlorouter,mlohadv,mlodyninit,watbdy,ipice,oldu1,oldv1,oldu2,oldv2
public gosig,gosigh,godsig

real, dimension(:), allocatable, save :: watbdy,ipice,ee,eeu,eev,dd,ddu,ddv
real, dimension(:), allocatable, save :: gosig,gosigh,godsig
real, dimension(:,:), allocatable, save :: oldu1,oldu2,oldv1,oldv2
real, dimension(:,:), allocatable, save :: stwgt
integer, parameter :: salfilt=0    ! additional salinity filter (0=off, 1=Katzfey)
integer, parameter :: usetide=1    ! tidal forcing (0=off, 1=on)
integer, parameter :: icemode=2    ! ice stress (0=free-drift, 1=incompressible, 2=cavitating)
integer, parameter :: basinmd=1    ! basin mode (0=soil, 1=redistribute, 2=pile-up)
integer, parameter :: nf     =2    ! power for horizontal diffusion reduction factor
real, parameter :: k_smag=0.4      ! horizontal diffusion (2. in Griffies (2000), 0.7-1. in POM (Mellor 2004))
real, parameter :: delphi=150.     ! horizontal diffusion reduction factor gradient
real, parameter :: rhosn =330.     ! density snow (kg m^-3)
real, parameter :: rhoic =900.     ! density ice  (kg m^-3)
real, parameter :: grav  =9.80616  ! gravitational constant (m s^-2)

contains

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! This subroutine initialises mlo dynamical arrays
!
subroutine mlodyninit

use cc_mpi
use indices_m
use mlo
use soil_m

implicit none

include 'newmpar.h'
include 'mpif.h'
include 'parm.h'

integer ii,iq,ierr
real, dimension(ifull,0:wlev) :: dephl
real, dimension(ifull,wlev) :: dep,dz
real, dimension(ifull+iextra,3) :: dumx,dumy
real, dimension(wlev) :: sig,sigh,dsig
real, dimension(3*wlev) :: dumz,gdumz
logical, dimension(ifull+iextra) :: wtr

! river water height
allocate(watbdy(ifull+iextra))
watbdy=0.

! prep land-sea mask
allocate(ee(ifull+iextra))
allocate(eeu(ifull+iextra),eev(ifull+iextra))
ee=0.
eeu=0.
eev=0. 
where(.not.land)
  ee(1:ifull)=1.
end where

! Calculate depth arrays (free suface term is included later)
allocate(dd(ifull+iextra))
allocate(ddu(ifull+iextra),ddv(ifull+iextra))
dd=0.
ddu=0.
ddv=0.
dep=0.
dz=0.
do ii=1,wlev
  call mloexpdep(0,dep(:,ii),ii,0)
  call mloexpdep(1,dz(:,ii),ii,0)
end do
dephl(:,0)=0.
dephl(:,1)=dz(:,1)
do ii=2,wlev
  dephl(:,ii)=dephl(:,ii-1)+dz(:,ii)
end do
dd(1:ifull)=dephl(:,wlev)

! update bounds values
dumx(1:ifull,1)=ee(1:ifull)
dumx(1:ifull,2)=dd(1:ifull)
call bounds(dumx(:,1:2),corner=.true.)
ee=dumx(:,1)
dd=dumx(:,2)
wtr=ee.gt.0.5

! Precompute weights for calculating staggered gradients
allocate(stwgt(ifull+iextra,2))
stwgt=0.
where (wtr(in).and.wtr(ine).and.wtr(is).and.wtr(ise).and.wtr(ie))
  stwgt(1:ifull,1)=1.
end where
where (wtr(ie).and.wtr(ien).and.wtr(iw).and.wtr(iwn).and.wtr(in))
  stwgt(1:ifull,2)=1.
end where

! update staggered bounds values
eeu(1:ifull)=ee(1:ifull)*ee(ie)
eev(1:ifull)=ee(1:ifull)*ee(in)
dd=max(dd,1.E-8)
ddu(1:ifull)=0.5*(dd(1:ifull)+dd(ie))
ddv(1:ifull)=0.5*(dd(1:ifull)+dd(in))
dumx(1:ifull,1)=eeu(1:ifull)
dumy(1:ifull,1)=eev(1:ifull)
dumx(1:ifull,2)=ddu(1:ifull)
dumy(1:ifull,2)=ddv(1:ifull)
dumx(1:ifull,3)=stwgt(1:ifull,1)
dumy(1:ifull,3)=stwgt(1:ifull,2)
call boundsuv(dumx(:,1:3),dumy(:,1:3))
eeu=dumx(:,1)
eev=dumy(:,1)
ddu=dumx(:,2)
ddv=dumy(:,2)
stwgt(:,1)=dumx(:,3)
stwgt(:,2)=dumy(:,3)

! sigma coordinates should be the same for all iq
allocate(gosig(wlev),gosigh(wlev),godsig(wlev))
do iq=1,ifull-1
  if (.not.land(iq)) exit
end do
do ii=1,wlev
  sig(ii)=dep(iq,ii)/dd(iq)
  sigh(ii)=dephl(iq,ii)/dd(iq)
  dsig(ii)=dz(iq,ii)/dd(iq)
end do
do iq=1,ifull
  if (.not.land(iq)) then
    do ii=1,wlev
      if (abs(sig(ii)*dd(iq)-dep(iq,ii)).gt.0.1.or.    &
          abs(sigh(ii)*dd(iq)-dephl(iq,ii)).gt.0.1.or. &
          abs(dsig(ii)*dd(iq)-dz(iq,ii)).gt.0.1) then
        write(6,*) "ERROR: MLO not configured for sigma levels"
        call MPI_Abort(MPI_COMM_WORLD,-1,ierr)
      end if
    end do
  end if
end do
dumz(1:wlev)=sig
dumz(wlev+1:2*wlev)=sigh
dumz(2*wlev+1:3*wlev)=dsig
call MPI_Allreduce ( dumz, gdumz, 3*wlev, MPI_REAL, MPI_MAX, MPI_COMM_WORLD, ierr )
gosig=gdumz(1:wlev)
gosigh=gdumz(wlev+1:2*wlev)
godsig=gdumz(2*wlev+1:3*wlev)

! dynamics save arrays
if (abs(nmlo).ge.3) then
  allocate(oldu1(ifull,wlev),oldv1(ifull,wlev))
  allocate(oldu2(ifull,wlev),oldv2(ifull,wlev))
  allocate(ipice(ifull+iextra))
  oldu1=0.
  oldv1=0.
  oldu2=oldu1
  oldv2=oldv1
  ipice=0.
end if

return
end subroutine mlodyninit

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! This subroutine processes horizontal diffusion, based on Griffies (2000)
! and McGregor's hordifg.f routines for CCAM.
subroutine mlodiffusion

use cc_mpi
use indices_m
use map_m
use mlo
use soil_m
use vecsuv_m

implicit none

include 'newmpar.h'
include 'const_phys.h'
include 'parm.h'

integer k,i,iq
real hdif,xp
real, dimension(ifull+iextra,wlev) :: u,v,uc,vc,wc
real, dimension(ifull+iextra,wlev) :: t_kh,xfact,yfact,gg
real, dimension(ifull,0:wlev) :: uhl,vhl
real, dimension(ifull,wlev) :: ff,base,dudz,dvdz
real, dimension(ifull+iextra) :: depadj,eta
real, dimension(ifull) :: dudx,dvdx,dudy,dvdy,tx_fact,ty_fact
real, dimension(ifull) :: cc,emi,nu,nv,nw,dedx,dedy
logical, dimension(ifull+iextra) :: wtr

hdif=dt*(k_smag/pi)**2
wtr=ee.gt.0.5
emi=1./em(1:ifull)**2

u=0.
v=0.
eta=0.
do k=1,wlev
  call mloexport(2,u(1:ifull,k),k,0)
  call mloexport(3,v(1:ifull,k),k,0)
end do
call mloexport(4,eta(1:ifull),0,0)
call boundsuv(u,v,allvec=.true.)
call bounds(eta)

! estimate u and v at half levels
uhl(:,0)=u(1:ifull,1)
vhl(:,0)=v(1:ifull,1)
do k=1,wlev-1
  xp=(gosigh(k)-gosig(k))/(gosig(k+1)-gosig(k))
  uhl(:,k)=u(1:ifull,k)+xp*(u(1:ifull,k+1)-u(1:ifull,k))
  vhl(:,k)=v(1:ifull,k)+xp*(v(1:ifull,k+1)-v(1:ifull,k))
end do
uhl(:,wlev)=u(1:ifull,wlev)
vhl(:,wlev)=v(1:ifull,wlev)

! vertical gradients
depadj(1:ifull)=max(dd(1:ifull)+eta(1:ifull),mindep)
dudz(:,1)=(uhl(:,1)-uhl(:,0))/(depadj(1:ifull)*gosigh(1))
dvdz(:,1)=(vhl(:,1)-vhl(:,0))/(depadj(1:ifull)*gosigh(1))
do k=2,wlev
  dudz(:,k)=(uhl(:,k)-uhl(:,k-1))/(depadj(1:ifull)*(gosigh(k)-gosigh(k-1)))
  dvdz(:,k)=(vhl(:,k)-vhl(:,k-1))/(depadj(1:ifull)*(gosigh(k)-gosigh(k-1)))
end do

! calculate (appproximate) gradients
dedx=0.5*(eta(ie)-eta(iw))*em(1:ifull)/ds
dedy=0.5*(eta(in)-eta(is))*em(1:ifull)/ds
do k=1,wlev
  dudx=0.5*(u(ieu,k)-u(iwu,k))*em(1:ifull)/ds+dudz(:,k)*(1.-gosig(k))*dedx
  dvdx=0.5*(v(iev,k)-v(iwv,k))*em(1:ifull)/ds+dvdz(:,k)*(1.-gosig(k))*dedx
  dudy=0.5*(u(inu,k)-u(isu,k))*em(1:ifull)/ds+dudz(:,k)*(1.-gosig(k))*dedy
  dvdy=0.5*(v(inv,k)-v(isv,k))*em(1:ifull)/ds+dvdz(:,k)*(1.-gosig(k))*dedy
  ! Smagorinsky
  cc=(dudx-dvdy)**2+(dudy+dvdx)**2
  t_kh(1:ifull,k)=sqrt(cc)*hdif*emi  ! this one with em in D terms
end do
call bounds(t_kh)
  
! convert to staggered coordinates
! reduce diffusion errors where bathymetry gradients are strong
do k=1,wlev
  depadj=gosig(k)*dd
  tx_fact=1./(1.+(abs(depadj(ie)-depadj(1:ifull))/delphi)**nf)
  ty_fact=1./(1.+(abs(depadj(in)-depadj(1:ifull))/delphi)**nf)
  xfact(1:ifull,k)=(t_kh(ie,k)+t_kh(1:ifull,k))*0.5 ! staggered
  yfact(1:ifull,k)=(t_kh(in,k)+t_kh(1:ifull,k))*0.5 ! staggered
  xfact(1:ifull,k)=xfact(1:ifull,k)*eeu(1:ifull) ! land boundary
  yfact(1:ifull,k)=yfact(1:ifull,k)*eev(1:ifull) ! land boundary
  xfact(1:ifull,k)=xfact(1:ifull,k)*tx_fact ! reduction factor
  yfact(1:ifull,k)=yfact(1:ifull,k)*ty_fact ! reduction factor
end do
call boundsuv(xfact,yfact)

! viscosity terms (closure #1)
do k=1,wlev
  uc(1:ifull,k)=ax(1:ifull)*u(1:ifull,k)+bx(1:ifull)*v(1:ifull,k)
  vc(1:ifull,k)=ay(1:ifull)*u(1:ifull,k)+by(1:ifull)*v(1:ifull,k)
  wc(1:ifull,k)=az(1:ifull)*u(1:ifull,k)+bz(1:ifull)*v(1:ifull,k)
end do
call bounds(uc)
call bounds(vc)
call bounds(wc)

do k=1,wlev

  base(:,k)=emi+xfact(1:ifull,k)+xfact(iwu,k)+yfact(1:ifull,k)+yfact(isv,k)

  nu = ( uc(1:ifull,k)*emi +                 &
         xfact(1:ifull,k)*uc(ie,k) +         &
         xfact(iwu,k)*uc(iw,k) +             &
         yfact(1:ifull,k)*uc(in,k) +         &
         yfact(isv,k)*uc(is,k) ) / base(:,k)

  nv = ( vc(1:ifull,k)*emi +                 &
         xfact(1:ifull,k)*vc(ie,k) +         &
         xfact(iwu,k)*vc(iw,k) +             &
         yfact(1:ifull,k)*vc(in,k) +         &
         yfact(isv,k)*vc(is,k) ) / base(:,k)

  nw = ( wc(1:ifull,k)*emi +                 &
         xfact(1:ifull,k)*wc(ie,k) +         &
         xfact(iwu,k)*wc(iw,k) +             &
         yfact(1:ifull,k)*wc(in,k) +         &
         yfact(isv,k)*wc(is,k) ) / base(:,k)

  u(1:ifull,k)=ax(1:ifull)*nu+ay(1:ifull)*nv+az(1:ifull)*nw
  v(1:ifull,k)=bx(1:ifull)*nu+by(1:ifull)*nv+bz(1:ifull)*nw

  call mloimport(2,u(1:ifull,k),k,0)
  call mloimport(3,v(1:ifull,k),k,0)

end do

! viscosity terms (closure #2)
!do k=1,wlev
!
!  base(:,k)=emi+xfact(1:ifull,k)+xfact(iwu,k)+yfact(1:ifull,k)+yfact(isv,k)
!
!  nu=(u(1:ifull,k)*emi+2.*xfact(1:ifull,k)*u(ieu,k)+2.*xfact(iwu,k)*u(iwu,k) &
!    +yfact(1:ifull,k)*u(inu,k)+yfact(isv,k)*u(isu,k)                         &
!    +(yfact(1:ifull,k)-yfact(isv,k))*0.5*(v(iev,k)-v(iwv,k))                 &
!    +t_kh(1:ifull,k)*0.5*(v(inv,k)+v(iev,k)-v(isv,k)-v(iwv,k)))              &
!    /(emi+2.*xfact(1:ifull,k)+2.*xfact(iwu,k)+yfact(1:ifull,k)+yfact(isv,k))
!  nv=(v(1:ifull,k)*emi+2.*yfact(1:ifull,k)*v(inv,k)+2.*yfact(isv,k)*v(isv,k) &
!    +xfact(1:ifull,k)*v(iev,k)+xfact(iwu,k)*v(iwv,k)                         &
!    +(xfact(1:ifull,k)-xfact(iwu,k))*0.5*(u(inu,k)-u(isu,k))                 &
!    +t_kh(1:ifull,k)*0.5*(u(inu,k)+u(ieu,k)-u(isu,k)-u(iwu,k)))              &
!    /(emi+2.*yfact(1:ifull,k)+2.*yfact(isv,k)+xfact(1:ifull,k)+xfact(iwu,k))
!
!  call mloimport(2,nu,k,0)
!  call mloimport(3,nv,k,0)
!
!end do

! update scalar variables
do i=0,1

  gg=0.
  do k=1,wlev
    call mloexport(i,gg(1:ifull,k),k,0)
  end do
  select case(i)
    case(0)
      gg(1:ifull,:)=gg(1:ifull,:)-290.
    case(1)
      gg(1:ifull,:)=gg(1:ifull,:)-34.72
  end select
  call bounds(gg)
  
  do k=1,wlev
    ff(:,k) = ( gg(1:ifull,k)*emi +                 &
                xfact(1:ifull,k)*gg(ie,k) +         &
                xfact(iwu,k)*gg(iw,k) +             &
                yfact(1:ifull,k)*gg(in,k) +         &
                yfact(isv,k)*gg(is,k) ) / base(:,k)
  end do
  select case(i)
    case(0)
      ff=ff+290.
    case(1)
      ff=ff+34.72
      where (ff.lt.0.1)
        ff=0.
      end where
  end select
  do k=1,wlev
    call mloimport(i,ff(:,k),k,0)
  end do
  
end do
  
! Jack Katzfey salinity filter
if (salfilt.eq.1) then
  gg(1:ifull,:)=ff
  call bounds(gg)
  do k=1,wlev
    ff(:,k) = ( gg(1:ifull,k)*emi +                 &
                xfact(1:ifull,k)*gg(ie,k) +         &
                xfact(iwu,k)*gg(iw,k) +             &
                yfact(1:ifull,k)*gg(in,k) +         &
                yfact(isv,k)*gg(is,k) ) / base(:,k)
    call mloimport(1,ff(:,k),k,0)
  end do
end if

return
end subroutine mlodiffusion

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! This subroutine calculates the river routing.
! This version currently assumes that the orography is sufficently resolved
! to determine the river flow.  Plan to read in effective gradients between
! grid boxes from high resolution river flow datasets.
subroutine mlorouter

use arrays_m
use cable_ccam 
use cc_mpi
use indices_m
use map_m
use mlo
use nsibd_m
use soil_m
use soilsnow_m

implicit none

include 'newmpar.h'
include 'const_phys.h'
include 'mpif.h'
include 'parm.h'
include 'soilv.h'

integer i,iq,ierr
integer, dimension(ifull,4) :: xp
real, dimension(ifull+iextra) :: neta,netvel
real, dimension(ifull+iextra,2) :: dum
real, dimension(ifull) :: newwat
real, dimension(ifull,4) :: idp,slope,mslope,vel,flow
real, dimension(2) :: dumb,gdumb
real :: xx,yy,lssum,gssum,lwsum,gwsum,netf,netg

! To speed up the code, we use a (semi-)implicit solution rather than an iterative approach
! This avoids additional MPI calls.

! Note that unlike Miller et al (1994), this scheme currently has multiple outflows from a given
! grid box (i.e., following Gordon in Mk3.5).  So if the slope of the grid box is divergent, then
! on average water leaves the grid box, whereas if the slop of the grid box is convergent, then on
! average water enters the grid box.

! The scheme currently does not support outflow from lakes.

xp(:,1)=in
xp(:,2)=ie
xp(:,3)=is
xp(:,4)=iw
idp(:,1)=emv(1:ifull)/ds
idp(:,2)=emu(1:ifull)/ds
idp(:,3)=emv(isv)/ds
idp(:,4)=emu(iwu)/ds

neta=0.
call mloexport(4,neta(1:ifull),0,0)
dum(1:ifull,1)=neta(1:ifull)
dum(1:ifull,2)=watbdy(1:ifull)
call bounds(dum(:,1:2))
neta=dum(:,1)
watbdy=dum(:,2)
newwat=watbdy(1:ifull)

slope=0.
do i=1,4
  !slope(:,i)=(zs(1:ifull)-zs(xp(:,i)))/(grav*dp(:,i))                       ! basic
  slope(:,i)=(zs(1:ifull)/grav+0.001*watbdy(1:ifull)+neta(1:ifull) &
             -zs(xp(:,i))/grav-0.001*watbdy(xp(:,i))-neta(xp(:,i)))*idp(:,i) ! flood
end do

! Basic expression

! flow = m * vel / dx
! m(t+1)-m(t) = dt*sum(inflow)-dt*sum(outflow)

! outflow
mslope=max(slope,0.)
vel=0.35*sqrt(mslope/0.00005) ! from Miller et al (1994)
where (mslope.gt.1.E-10)
  vel=min(max(vel,0.15),5.)
elsewhere
  vel=0.
end where
! compute net velocity for a grid box so that total water is conserved
netvel(1:ifull)=sum(vel,2)
call bounds(netvel)
flow=0.
do i=1,4
  where (netvel(1:ifull).gt.0.)
    flow(:,i)=watbdy(1:ifull)*max(-dt*vel(:,i)*idp(:,i),-vel(:,i)/netvel(1:ifull)) ! (kg/m^2)
  end where
end do
newwat=newwat+sum(flow,2)

! inflow
mslope=max(-slope,0.)
vel=0.35*sqrt(mslope/0.00005) ! from Miller et al (1994)
where (mslope.gt.1.E-10)
  vel=min(max(vel,0.15),5.)
elsewhere
  vel=0.
end where
flow=0.
do i=1,4
  where (netvel(xp(:,i)).gt.0.)
    flow(:,i)=watbdy(xp(:,i))*min(dt*vel(:,i)*idp(:,i),vel(:,i)/netvel(xp(:,i))) ! (kg/m^2)
    flow(:,i)=flow(:,i)*em(1:ifull)*em(1:ifull)/(em(xp(:,i))*em(xp(:,i))) ! change in gridbox area
  end where
end do
newwat=newwat+sum(flow,2)

watbdy(1:ifull)=max(newwat,0.)
  
! basin
select case(basinmd)
  case(0)
    ! add water to soil moisture 
    if (nsib==6.or.nsib==7) then
      do iq=1,ifull
        if (all(slope(iq,:).lt.-1.E-10).and.land(iq)) then
          ! runoff is inserted into soil moisture since CCAM has discrete land and sea points
          xx=watbdy(iq)
          call cableinflow(iq,xx)
          newwat(iq)=newwat(iq)+(xx-watbdy(iq))*(1.-sigmu(iq))
        end if
      end do
    else
      do iq=1,ifull
        if (all(slope(iq,:).lt.-1.E-10).and.land(iq)) then
          ! runoff is inserted into soil moisture since CCAM has discrete land and sea points
          xx=watbdy(iq)
          yy=min(xx,(ssat(isoilm(iq))-wb(iq,ms))*1000.*zse(ms))
          wb(iq,ms)=wb(iq,ms)+yy/(1000.*zse(ms))
          xx=max(xx-yy,0.)
          newwat(iq)=newwat(iq)+(xx-watbdy(iq))*(1.-sigmu(iq))
        end if
      end do
    end if
  case(1)
    ! distribute water over ocean (used when soil column is too shallow)
    lssum=0.
    lwsum=0.
    do iq=1,ifull
      if (all(slope(iq,:).lt.-1.E-10).and.land(iq)) then
        lssum=lssum+newwat(iq)/(em(iq)*em(iq)) ! kg of water / (ds*ds)
        newwat(iq)=0.
      elseif (.not.land(iq)) then
        lwsum=lwsum+1./(em(iq)*em(iq))   
      end if
    end do
    dumb(1)=lssum
    dumb(2)=lwsum
    call MPI_AllReduce(dumb,gdumb,2,MPI_REAL,MPI_SUM,MPI_COMM_WORLD,ierr)
    gssum=gdumb(1)
    gwsum=gdumb(2)
    xx=gssum/max(gwsum,0.1)
    where (.not.land)
      neta(1:ifull)=neta(1:ifull)+xx*0.001
    end where
    call mloimport(4,neta(1:ifull),0,0)
  case(2)
    ! pile-up water
  case default
    write(6,*) "ERROR: Unsupported basinmd ",basinmd
    stop
end select

watbdy(1:ifull)=max(newwat,0.)

return
end subroutine mlorouter

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! This subroutine implements some basic hydrostatic dynamics for the
! ocean and ice.  The ocean component employs the R-grid design used
! in CCAM semi-Lagragain dynamics, but uses sigma z vertical
! coordinates.  The staggered/unstaggered pivoting has been modified
! for the land-sea boundary.  Sea-ice is advected using an upwind
! scheme.  Internal sea-ice pressure follows a cavitating fluid
! apporximation.
subroutine mlohadv

use arrays_m
use cc_mpi
use infile
use indices_m
use latlong_m
use map_m
use mlo
use nharrs_m, only : lrestart
use soil_m
use soilsnow_m
use vecsuv_m

implicit none

include 'newmpar.h'
include 'const_phys.h'
include 'mpif.h'
include 'parm.h'

integer leap
common/leap_yr/leap  ! 1 to allow leap years

integer iq,ll,ii,ierr,totits,itotits
integer jyear,jmonth,jday,jhour,jmin,mins
integer tyear,jstart,iip,iim
integer, dimension(ifull,wlev) :: nface
real alpha,maxloclseta,maxglobseta,maxloclip,maxglobip
real delpos,delneg,alph_p,dumpp,dumpn,fjd
real, dimension(ifull+iextra) :: neta,pice,imass
real, dimension(ifull+iextra) :: nfracice,ndic,ndsn,nsto,niu,niv,nis,ndum
real, dimension(ifull+iextra) :: snu,sou,spu,squ,sru,snv,sov,spv,sqv,srv
real, dimension(ifull+iextra) :: ibu,ibv,icu,icv,spnet,oeta,oeu,oev
real, dimension(ifull) :: i_u,i_v,i_sto,i_sal,rhobaru,rhobarv
real, dimension(ifull) :: sdiv,sinp,div,inp,odiv,seta,w_e
real, dimension(ifull) :: sdivb,divb,odivb,xps
real, dimension(ifull) :: tnu,tsu,tev,twv,rhou,rhov
real, dimension(ifull) :: dpsdxu,dpsdyu,dpsdxv,dpsdyv
real, dimension(ifull) :: dttdxu,dttdyu,dttdxv,dttdyv
real, dimension(ifull) :: detadxu,detadyu,detadxv,detadyv
real, dimension(ifull) :: dipdxu,dipdyu,dipdxv,dipdyv
real, dimension(ifull) :: au,bu,cu,av,bv,cv,odum
real, dimension(ifull) :: nip,ipmax,imu,imv
real, dimension(ifull) :: sue,suw,svn,svs,snuw,snvs
real, dimension(ifull+iextra,wlev+1) :: eou,eov
real, dimension(ifull+iextra,wlev) :: nu,nv,nt,ns,mps
real, dimension(ifull+iextra,wlev) :: cou,cov,cow
real, dimension(ifull+iextra,wlev) :: rhobar,rho,dalpha,dbeta
real, dimension(ifull+iextra,7) :: dumc,dumd
real, dimension(ifull+iextra,4) :: nit
real, dimension(ifull+iextra,1) :: sku,skv
real, dimension(ifull,1) :: uiu,uiv,siu,siv,sju,sjv
real, dimension(ifull,4) :: i_it
real, dimension(ifull,wlev) :: w_u,w_v,w_t,w_s,dum
real, dimension(ifull,wlev) :: nuh,nvh,xg,yg,uau,uav,dou,dov,tau,tav
real, dimension(ifull,wlev) :: kku,llu,mmu,nnu
real, dimension(ifull,wlev) :: kkv,llv,mmv,nnv
real, dimension(ifull,wlev) :: drhobardxu,drhobardyu,drhobardxv,drhobardyv
real, dimension(ifull,wlev) :: depdum,dzdum
real, dimension(ifull,wlev) :: dumt,dums,dumr,duma,dumb
real, dimension(ifull,0:wlev) :: nw
real*8, dimension(ifull,wlev) :: x3d,y3d,z3d
logical, dimension(ifull+iextra) :: wtr
logical lleap

integer, parameter :: llmax=300    ! iterations for calculating surface height
integer, parameter :: nxtrrho=1    ! Estimate rho at t+1
real, parameter :: tol  = 2.E-3    ! Tolerance for GS solver (water)
real, parameter :: itol = 2.E1     ! Tolerance for GS solver (ice)
real, parameter :: sal  = 0.948    ! SAL parameter for tidal forcing
real, parameter :: eps  = 0.1      ! Off-centring term

! new z levels for including free surface eta (effectively sigma-depth levels)
! newz=-eta+oldz*(1+eta/maxdepth)
! newdz=olddz*(1+eta/maxdepth)
! where 0<=oldz<=maxdepth and -eta<=newz<=maxdepth
! depth below free suface is newz+eta=oldz*(1+eta/maxdepth)

! Instead of packing ocean points, we keep the original
! grid and define a land/sea mask.  This allows us to
! use the same index and map factor arrays from the
! atmospheric dynamical core.

if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: Start"
end if

! Define land/sea mask
wtr=ee.gt.0.5

! Default values
w_t=273.16
w_s=34.72
w_u=0.
w_v=0.
w_e=0.
i_it=273.16
i_sto=0.
i_u=0.
i_v=0.
i_sal=0.
rho=0.
nw=0.

! IMPORT WATER AND ICE DATA -----------------------------------------
if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: Import"
end if
do ii=1,wlev
  call mloexport(0,w_t(:,ii),ii,0)
  call mloexport(1,w_s(:,ii),ii,0)
  call mloexport(2,w_u(:,ii),ii,0)
  call mloexport(3,w_v(:,ii),ii,0)
end do
call mloexport(4,w_e,0,0)
do ii=1,4
  call mloexpice(i_it(:,ii),ii,0)
end do
call mloexpice(fracice,5,0)
call mloexpice(sicedep,6,0)
call mloexpice(snowd,7,0)
call mloexpice(i_sto,8,0)
call mloexpice(i_u,9,0)
call mloexpice(i_v,10,0)
call mloexpice(i_sal,11,0)

! estimate tidal forcing (assumes leap days)
if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: Tides"
end if
if (usetide.eq.1) then
  call getzinp(fjd,jyear,jmonth,jday,jhour,jmin,mins)
  jstart=0
  if (jyear.gt.1900) then
    do tyear=1900,jyear-1
      call mloleap(tyear,lleap)
      if (lleap) jstart=jstart+1
      jstart=jstart+365
    end do
  else if (jyear.lt.1900) then
    do tyear=1899,jyear,-1
      call mloleap(tyear,lleap)
      if (lleap) jstart=jstart-1
      jstart=jstart-365
    end do
  end if
  mins=mins+720 ! base time is 12Z 31 Dec 1899
  if (leap.eq.0.and.jmonth.gt.2) mins=mins+1440 ! fix for leap==0
  call mlotide(ndum(1:ifull),rlongg,rlatt,mins,jstart)
else
  ndum(1:ifull)=0.
end if

! initialise t+1 variables with t data
neta(1:ifull)=w_e
nu(1:ifull,:)=w_u
nv(1:ifull,:)=w_v
nt(1:ifull,:)=w_t
ns(1:ifull,:)=w_s
nfracice=0.
ndic=0.
ndsn=0.
where (wtr(1:ifull))
  nfracice(1:ifull)=fracice
  ndic(1:ifull)=sicedep
  ndsn(1:ifull)=snowd*0.001
end where
nit(1:ifull,:)=i_it
nsto(1:ifull)=i_sto
niu(1:ifull)=i_u
niv(1:ifull)=i_v
nis(1:ifull)=i_sal
neta(1:ifull)=max(neta(1:ifull),-dd(1:ifull)+mindep)

totits=0
itotits=0

! surface pressure gradients (including ice)
! (assume ice velocity is 'slow' compared to 'fast' change in neta)
imass(1:ifull)=ndic(1:ifull)*rhoic+ndsn(1:ifull)*rhosn          ! ice mass per unit area (kg/m^2), unstaggered at time t
pice(1:ifull)=ps(1:ifull)+grav*nfracice(1:ifull)*imass(1:ifull) ! pressure due to atmosphere and ice at top of water column (unstaggered at t)

! Limit minimum ice mass for ice velocity calculation.  Hence we can estimate the ice velocity at
! grid points where the ice is not yet present.  
imass(1:ifull)=max(imass(1:ifull),10.)

! update scalar bounds and various gradients
dumc(1:ifull,1)=neta(1:ifull)
dumc(1:ifull,2)=pice(1:ifull)
dumc(1:ifull,3)=ndum(1:ifull)
dumc(1:ifull,4)=imass(1:ifull)
call bounds(dumc(:,1:4),corner=.true.)
neta=dumc(:,1)
pice=dumc(:,2)
ndum=dumc(:,3)
imass=dumc(:,4)
! surface pressure
tnu=0.5*(pice(in)+pice(ine))
tsu=0.5*(pice(is)+pice(ise))
tev=0.5*(pice(ie)+pice(ien))
twv=0.5*(pice(iw)+pice(iwn))
dpsdxu=(pice(ie)-pice(1:ifull))*emu(1:ifull)/ds ! staggered at time t
dpsdyu=stwgt(1:ifull,1)*0.5*(tnu-tsu)*emu(1:ifull)/ds
dpsdxv=stwgt(1:ifull,2)*0.5*(tev-twv)*emv(1:ifull)/ds
dpsdyv=(pice(in)-pice(1:ifull))*emv(1:ifull)/ds
! tides
tnu=0.5*(ndum(in)+ndum(ine))
tsu=0.5*(ndum(is)+ndum(ise))
tev=0.5*(ndum(ie)+ndum(ien))
twv=0.5*(ndum(iw)+ndum(iwn))
dttdxu=(ndum(ie)-ndum(1:ifull))*emu(1:ifull)/ds ! staggered
dttdyu=stwgt(1:ifull,1)*0.5*(tnu-tsu)*emu(1:ifull)/ds
dttdxv=stwgt(1:ifull,2)*0.5*(tev-twv)*emv(1:ifull)/ds
dttdyv=(ndum(in)-ndum(1:ifull))*emv(1:ifull)/ds  
! save neta at t
oeta=neta

! ADVECT WATER ----------------------------------------------------
! Water currents are advected using semi-Lagrangian advection
! based on McGregor's CCAM advection routines.
! Velocity is set to zero at ocean boundaries.

if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: Departure points"
end if

! save arrays
if (ktau.eq.1.and..not.lrestart) then
  oldu1=nu(1:ifull,:)
  oldv1=nv(1:ifull,:)
  oldu2=nu(1:ifull,:)
  oldv2=nv(1:ifull,:)
  ipice=0. ! ice free drift solution
end if

! Estimate currents at t+1/2 for semi-Lagrangian advection
do ii=1,wlev
  nuh(:,ii)=(15.*nu(1:ifull,ii)-10.*oldu1(:,ii)+3.*oldu2(:,ii))/8.*ee(1:ifull) ! U at t+1/2
  nvh(:,ii)=(15.*nv(1:ifull,ii)-10.*oldv1(:,ii)+3.*oldv2(:,ii))/8.*ee(1:ifull) ! V at t+1/2
end do

! Calculate depature points
call mlodeps(nuh,nvh,nface,xg,yg,x3d,y3d,z3d,wtr)

oldu2=oldu1
oldv2=oldv1
oldu1=nu(1:ifull,:)
oldv1=nv(1:ifull,:)

if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: density EOS 1"
end if

! Calculate adjusted depths and thicknesses
odum=max(1.+neta(1:ifull)/dd(1:ifull),mindep/dd(1:ifull))
do ii=1,wlev
  depdum(:,ii)=gosig(ii)*dd(1:ifull)*odum
  dzdum(:,ii)=godsig(ii)*dd(1:ifull)*odum
end do

! Calculate normalised density rhobar (unstaggered at time t)
! (Assume free surface correction is small so that changes in the compression 
! effect due to neta can be neglected.  Consequently, the neta dependence is 
! separable in the iterative loop)
dumt=nt(1:ifull,:)
dums=ns(1:ifull,:)
call mloexpdensity(dumr,duma,dumb,dumt,dums,depdum,dzdum,pice(1:ifull),0)
rho(1:ifull,:)=dumr
dalpha(1:ifull,:)=duma
dbeta(1:ifull,:)=dumb
call bounds(rho)
call bounds(dalpha)
call bounds(dbeta)
call bounds(nt,corner=.true.)
call bounds(ns,corner=.true.)
rhobar(:,1)=(rho(:,1)-1030.)*godsig(1)
do ii=2,wlev
  rhobar(:,ii)=rhobar(:,ii-1)+(rho(:,ii)-1030.)*godsig(ii)
end do
do ii=1,wlev
  rhobar(:,ii)=rhobar(:,ii)/gosigh(ii)+1030.
end do

! Calculate normalised density gradients
! method 1: calculate along sigma levels.
!do ii=1,wlev
!  iip=min(ii+1,wlev)
!  iim=max(ii-1,1)
!  drhobardzu=(rhobar(1:ifull,iip)+rhobar(ie,iip)-rhobar(1:ifull,iim)-rhobar(ie,iim))          &
!            /(dep(1:ifull,iip)+dep(ie,iip)-dep(1:ifull,iim)-dep(ie,iim))
!  drhobardzv=(rhobar(1:ifull,iip)+rhobar(in,iip)-rhobar(1:ifull,iim)-rhobar(in,iim))          &
!            /(dep(1:ifull,iip)+dep(in,iip)-dep(1:ifull,iim)-dep(in,iim))
!  tnu=0.5*( rhobar(in,ii)+drhobardzu*((1.-gosig(ii))*neta(in) -gosig(ii)*dd(in) ) &
!          +rhobar(ine,ii)+drhobardzu*((1.-gosig(ii))*neta(ine)-gosig(ii)*dd(ine)))
!  tsu=0.5*( rhobar(is,ii)+drhobardzu*((1.-gosig(ii))*neta(is) -gosig(ii)*dd(is) ) &
!          +rhobar(ise,ii)+drhobardzu*((1.-gosig(ii))*neta(ise)-gosig(ii)*dd(ise)))
!  tev=0.5*( rhobar(ie,ii)+drhobardzv*((1.-gosig(ii))*neta(ie) -gosig(ii)*dd(ie) ) &
!          +rhobar(ien,ii)+drhobardzv*((1.-gosig(ii))*neta(ien)-gosig(ii)*dd(ien)))
!  twv=0.5*( rhobar(iw,ii)+drhobardzv*((1.-gosig(ii))*neta(iw) -gosig(ii)*dd(iw) ) &
!          +rhobar(iwn,ii)+drhobardzv*((1.-gosig(ii))*neta(iwn)-gosig(ii)*dd(iwn)))
!  drhobardxu(:,ii)=(rhobar(ie,ii)-rhobar(1:ifull,ii)+drhobardzu*((1.-gosig(ii))*(neta(ie)-neta(1:ifull)) &
!                                                     -gosig(ii)*(dd(ie)-dd(1:ifull))))*emu(1:ifull)/ds
!  drhobardxu(:,ii)=drhobardxu(:,ii)*eeu(1:ifull)                                                   
!  drhobardyu(:,ii)=stwgt(1:ifull,1)*0.5*(tnu-tsu)*emu(1:ifull)/ds
!  drhobardxv(:,ii)=stwgt(1:ifull,2)*0.5*(tev-twv)*emv(1:ifull)/ds
!  drhobardyv(:,ii)=(rhobar(in,ii)-rhobar(1:ifull,ii)+drhobardzv*((1.-gosig(ii))*(neta(in)-neta(1:ifull)) &
!                                                     -gosig(ii)*(dd(in)-dd(1:ifull))))*emv(1:ifull)/ds
!  drhobardyv(:,ii)=drhobardyv(:,ii)*eev(1:ifull)
!end do
! method 2: Use potential temperature and salinity Jacobians (see Shchepetkin and McWilliams 2003)
call tsjacobi(nt,ns,dalpha,dbeta,neta,drhobardxu,drhobardyu,drhobardxv,drhobardyv)
drhobardxu(:,1)=drhobardxu(:,1)*godsig(1)
drhobardxv(:,1)=drhobardxv(:,1)*godsig(1)
drhobardyu(:,1)=drhobardyu(:,1)*godsig(1)
drhobardyv(:,1)=drhobardyv(:,1)*godsig(1)
do ii=2,wlev
  drhobardxu(:,ii)=drhobardxu(:,ii-1)+drhobardxu(:,ii)*godsig(ii)
  drhobardxv(:,ii)=drhobardxv(:,ii-1)+drhobardxv(:,ii)*godsig(ii)
  drhobardyu(:,ii)=drhobardyu(:,ii-1)+drhobardyu(:,ii)*godsig(ii)
  drhobardyv(:,ii)=drhobardyv(:,ii-1)+drhobardyv(:,ii)*godsig(ii)
end do
do ii=1,wlev
  drhobardxu(:,ii)=drhobardxu(:,ii)/gosigh(ii)
  drhobardxv(:,ii)=drhobardxv(:,ii)/gosigh(ii)
  drhobardyu(:,ii)=drhobardyu(:,ii)/gosigh(ii)
  drhobardyv(:,ii)=drhobardyv(:,ii)/gosigh(ii)
end do

if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: continuity equation"
end if

! Advect continuity equation to tstar
! Calculate velocity on C-grid for consistancy with iterative free surface calculation
! nw is at half levels with nw(:,1) at the bottom of level 1
! positive nw is moving downwards to the ocean bottom
! For now, assume Boussinesq fluid and treat density in continuity equation as constant
! true vertical velocity = nw-u*((1-sig)*deta/dx-sig*d(dd)/dx)-v*((1-sig)*deta/dy-sig*d(dd)/dy)-(1-sig)*deta/dt
dumt=nu(1:ifull,:)
dums=nv(1:ifull,:)
call mlostaguv(dumt,dums,duma,dumb)
! surface height at staggered coordinate
oeu(1:ifull)=0.5*(neta(1:ifull)+neta(ie)) ! height at staggered coordinate
oev(1:ifull)=0.5*(neta(1:ifull)+neta(in)) ! height at staggered coordinate
eou(1:ifull,1:wlev)=duma
eov(1:ifull,1:wlev)=dumb
eou(1:ifull,wlev+1)=oeu(1:ifull)
eov(1:ifull,wlev+1)=oev(1:ifull)
call boundsuv(eou,eov)
oeu=eou(:,wlev+1)*eeu
oev=eov(:,wlev+1)*eev
dou(:,1)=nu(1:ifull,1)*godsig(1)*ee(1:ifull) ! unstaggered at time t
dov(:,1)=nv(1:ifull,1)*godsig(1)*ee(1:ifull)
cou(:,1)=eou(:,1)*godsig(1)*eeu
cov(:,1)=eov(:,1)*godsig(1)*eev
do ii=2,wlev
  dou(:,ii)=(dou(:,ii-1)+nu(1:ifull,ii)*godsig(ii))*ee(1:ifull)
  dov(:,ii)=(dov(:,ii-1)+nv(1:ifull,ii)*godsig(ii))*ee(1:ifull)
  cou(:,ii)=(cou(:,ii-1)+eou(:,ii)*godsig(ii))*eeu
  cov(:,ii)=(cov(:,ii-1)+eov(:,ii)*godsig(ii))*eev
end do
sju(:,1)=(oeu(1:ifull)/emu(1:ifull)-oeu(iwu)/emu(iwu))*em(1:ifull)*em(1:ifull)/ds ! unstaggered
sjv(:,1)=(oev(1:ifull)/emv(1:ifull)-oev(isv)/emv(isv))*em(1:ifull)*em(1:ifull)/ds
sdiv=(cou(1:ifull,wlev)*(ddu(1:ifull)+neta(1:ifull))/emu(1:ifull)-cou(iwu,wlev)*(ddu(iwu)+neta(1:ifull))/emu(iwu)  &
     +cov(1:ifull,wlev)*(ddv(1:ifull)+neta(1:ifull))/emv(1:ifull)-cov(isv,wlev)*(ddv(isv)+neta(1:ifull))/emv(isv)) &
     *em(1:ifull)*em(1:ifull)/ds
sinp=-(dou(:,wlev)*sju(:,1)+dov(:,wlev)*sjv(:,1))
do ii=1,wlev-1
  div=(cou(1:ifull,ii)*(ddu(1:ifull)+neta(1:ifull))/emu(1:ifull)-cou(iwu,ii)*(ddu(iwu)+neta(1:ifull))/emu(iwu)  &
      +cov(1:ifull,ii)*(ddv(1:ifull)+neta(1:ifull))/emv(1:ifull)-cov(isv,ii)*(ddv(isv)+neta(1:ifull))/emv(isv)) &
      *em(1:ifull)*em(1:ifull)/ds
  inp=-(dou(:,ii)*sju(:,1)+dov(:,ii)*sjv(:,1))
  nw(:,ii)=((sdiv-sinp)*gosigh(ii)-div+inp)*ee(1:ifull)
end do
! compute contunity equation horizontal transport terms
do ii=1,wlev
  div=(eou(1:ifull,ii)*(ddu(1:ifull)+neta(1:ifull))/emu(1:ifull)-eou(iwu,ii)*(ddu(iwu)+neta(1:ifull))/emu(iwu)  &
      +eov(1:ifull,ii)*(ddv(1:ifull)+neta(1:ifull))/emv(1:ifull)-eov(isv,ii)*(ddv(isv)+neta(1:ifull))/emv(isv)) &
      *em(1:ifull)*em(1:ifull)/ds
  div=div+(nw(:,ii)-nw(:,ii-1))/godsig(ii) ! nw is at half levels
  mps(1:ifull,ii)=neta(1:ifull)-(1.-eps)*0.5*dt*div
end do

if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: pressure gradient terms"
end if

! Prepare pressure gradient terms at t=t and incorporate into velocity field
do ii=1,wlev
  rhou=0.5*(rho(1:ifull,ii)+rho(ie,ii))
  rhov=0.5*(rho(1:ifull,ii)+rho(in,ii))
  rhobaru=0.5*(rhobar(1:ifull,ii)+rhobar(ie,ii))
  rhobarv=0.5*(rhobar(1:ifull,ii)+rhobar(in,ii))
  uau(:,ii)=grav*(gosig(ii)*(oeu(1:ifull)+ddu(1:ifull))*drhobardxu(:,ii)+rhobaru*(neta(ie)-neta(1:ifull))*emu(1:ifull)/ds)/rhou ! staggered
  uav(:,ii)=grav*(gosig(ii)*(oev(1:ifull)+ddv(1:ifull))*drhobardyv(:,ii)+rhobarv*(neta(in)-neta(1:ifull))*emv(1:ifull)/ds)/rhov
end do
call mlounstaguv(uau,uav,tau,tav) ! trick from JLM
do ii=1,wlev
  uau(:,ii)=nu(1:ifull,ii)+(1.-eps)*0.5*dt*( f(1:ifull)*nv(1:ifull,ii)-tau(:,ii)) ! unstaggered
  uav(:,ii)=nv(1:ifull,ii)+(1.-eps)*0.5*dt*(-f(1:ifull)*nu(1:ifull,ii)-tav(:,ii))
  uau(:,ii)=uau(:,ii)*ee(1:ifull)
  uav(:,ii)=uav(:,ii)*ee(1:ifull)
end do

if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: water vertical advection 1"
end if

! Vertical advection (first call for 0.5*dt)
dums=ns(1:ifull,:)
dumt=nt(1:ifull,:)
duma=mps(1:ifull,:)
call mlovadv(0.5*dt,nw,uau,uav,dums,dumt,duma,depdum,dzdum,wtr(1:ifull),1)
ns(1:ifull,:)=dums
nt(1:ifull,:)=dumt
mps(1:ifull,:)=duma

if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: horizontal advection"
end if

! Convert (u,v) to cartesian coordinates (U,V,W)
do ii=1,wlev
  cou(1:ifull,ii)=ax(1:ifull)*uau(:,ii)+bx(1:ifull)*uav(:,ii)
  cov(1:ifull,ii)=ay(1:ifull)*uau(:,ii)+by(1:ifull)*uav(:,ii)
  cow(1:ifull,ii)=az(1:ifull)*uau(:,ii)+bz(1:ifull)*uav(:,ii)
end do

! Advect continuity terms
call mlob2intsb(mps,nface,xg,yg,wtr)

! Horizontal advection for U,V,W
call mlob2ints(cou,nface,xg,yg,wtr)
call mlob2ints(cov,nface,xg,yg,wtr)
call mlob2ints(cow,nface,xg,yg,wtr)

! Horizontal advection for T,S
nt(1:ifull,:)=nt(1:ifull,:)-290.
ns(1:ifull,:)=ns(1:ifull,:)-34.72
call mlob2intsb(nt,nface,xg,yg,wtr)
call mlob2intsb(ns,nface,xg,yg,wtr)
nt(1:ifull,:)=nt(1:ifull,:)+290.
ns(1:ifull,:)=ns(1:ifull,:)+34.72
 
! Rotate vector to arrival point
call mlorot(cou(1:ifull,:),cov(1:ifull,:),cow(1:ifull,:),x3d,y3d,z3d)

! Convert (U,V,W) back to conformal cubic coordinates
do ii=1,wlev
  uau(:,ii)=ax(1:ifull)*cou(1:ifull,ii)+ay(1:ifull)*cov(1:ifull,ii)+az(1:ifull)*cow(1:ifull,ii)
  uav(:,ii)=bx(1:ifull)*cou(1:ifull,ii)+by(1:ifull)*cov(1:ifull,ii)+bz(1:ifull)*cow(1:ifull,ii)
  uau(:,ii)=uau(:,ii)*ee(1:ifull)
  uav(:,ii)=uav(:,ii)*ee(1:ifull)
end do

if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: water vertical advection 2"
end if

! Vertical advection (second call for 0.5*dt)
! use explicit nw and depdum,dzdum from t=tau step (i.e., following JLM in CCAM atmospheric dynamics)
! Could use nuh and nvh to estimate nw at t+1/2, but also require an estimate of neta at t+1/2
dums=ns(1:ifull,:)
dumt=nt(1:ifull,:)
duma=mps(1:ifull,:)
call mlovadv(0.5*dt,nw,uau,uav,dums,dumt,duma,depdum,dzdum,wtr(1:ifull),2)
ns(1:ifull,:)=dums
nt(1:ifull,:)=dumt
mps(1:ifull,:)=duma

! Integrate advected mps
xps=mps(1:ifull,1)*godsig(1)
do ii=2,wlev
  xps=xps+mps(1:ifull,ii)*godsig(ii)
end do
xps=xps*ee(1:ifull)

if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: density EOS 2"
end if

! Approximate normalised density rhobar at t+1 (unstaggered, using T and S at t+1)
if (nxtrrho==1) then
  dumt=nt(1:ifull,:)
  dums=ns(1:ifull,:)
  call mloexpdensity(dumr,duma,dumb,dumt,dums,depdum,dzdum,pice(1:ifull),0)
  rho(1:ifull,:)=dumr
  dalpha(1:ifull,:)=duma
  dbeta(1:ifull,:)=dumb
  call bounds(rho)
  call bounds(dalpha)
  call bounds(dbeta)
  call bounds(nt,corner=.true.)
  call bounds(ns,corner=.true.)
  rhobar(:,1)=(rho(:,1)-1030.)*godsig(1)
  do ii=2,wlev
    rhobar(:,ii)=rhobar(:,ii-1)+(rho(:,ii)-1030.)*godsig(ii)
  end do
  do ii=1,wlev
    rhobar(:,ii)=rhobar(:,ii)/gosigh(ii)+1030.
  end do

  ! update normalised density gradients
  ! method 2
  call tsjacobi(nt,ns,dalpha,dbeta,neta,drhobardxu,drhobardyu,drhobardxv,drhobardyv)
  drhobardxu(:,1)=drhobardxu(:,1)*godsig(1)
  drhobardxv(:,1)=drhobardxv(:,1)*godsig(1)
  drhobardyu(:,1)=drhobardyu(:,1)*godsig(1)
  drhobardyv(:,1)=drhobardyv(:,1)*godsig(1)
  do ii=2,wlev
    drhobardxu(:,ii)=drhobardxu(:,ii-1)+drhobardxu(:,ii)*godsig(ii)
    drhobardxv(:,ii)=drhobardxv(:,ii-1)+drhobardxv(:,ii)*godsig(ii)
    drhobardyu(:,ii)=drhobardyu(:,ii-1)+drhobardyu(:,ii)*godsig(ii)
    drhobardyv(:,ii)=drhobardyv(:,ii-1)+drhobardyv(:,ii)*godsig(ii)
  end do
  do ii=1,wlev
    drhobardxu(:,ii)=drhobardxu(:,ii)/gosigh(ii)
    drhobardxv(:,ii)=drhobardxv(:,ii)/gosigh(ii)
    drhobardyu(:,ii)=drhobardyu(:,ii)/gosigh(ii)
    drhobardyv(:,ii)=drhobardyv(:,ii)/gosigh(ii)
  end do
end if


! FREE SURFACE CALCULATION ----------------------------------------

if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: free surface"
end if

! Prepare integral terms
sou=0.
spu=0.
squ=0.
sru=0.
sov=0.
spv=0.
sqv=0.
srv=0.

! Precompute U,V current and integral terms at t+1
do ii=1,wlev
  snu(1:ifull)=uau(:,ii)
  snv(1:ifull)=uav(:,ii)
  uau(:,ii)=uau(:,ii)+0.5*dt*(1.+eps)*f(1:ifull)*snv(1:ifull)
  uav(:,ii)=uav(:,ii)-0.5*dt*(1.+eps)*f(1:ifull)*snu(1:ifull)
end do
call mlostaguv(uau,uav,duma,dumb)
cou(1:ifull,:)=duma
cov(1:ifull,:)=dumb
odum=1./(1.+(1.+eps)*(1.+eps)*0.25*dt*dt*fu(1:ifull)*fu(1:ifull))
siu(:,1)=-(1.+eps)*0.5*dt*odum
do ii=1,wlev
  cou(1:ifull,ii)=cou(1:ifull,ii)*odum ! staggered
end do
odum=1./(1.+(1.+eps)*(1.+eps)*0.25*dt*dt*fv(1:ifull)*fv(1:ifull))
siv(:,1)=-(1.+eps)*0.5*dt*odum
do ii=1,wlev
  cov(1:ifull,ii)=cov(1:ifull,ii)*odum ! staggered
end do
do ii=1,wlev
  rhou=0.5*(rho(1:ifull,ii)+rho(ie,ii))
  rhov=0.5*(rho(1:ifull,ii)+rho(in,ii))
  rhobaru=0.5*(rhobar(1:ifull,ii)+rhobar(ie,ii))
  rhobarv=0.5*(rhobar(1:ifull,ii)+rhobar(in,ii))

  ! Create arrays to calcuate u and v at t+1, based on pressure gradient at t+1

  ! u^(t+1) = nu = au^(t*) + bu*dpdx^(t+1) + cu*dpdy^(t+1) (staggered)
  ! v^(t+1) = nv = av^(t*) + bv*dpdy^(t+1) + cv*dpdx^(t+1) (staggered)

  au=cou(1:ifull,ii)
  bu=siu(:,1)/rhou
  cu= (1.+eps)*0.5*dt*fu(1:ifull)*bu

  av=cov(1:ifull,ii)
  bv=siv(:,1)/rhov
  cv=-(1.+eps)*0.5*dt*fv(1:ifull)*bv

  ! Note pressure gradients are along constant newz surfaces
  !dppdxu=dpsdxu+grav*sig*(etau+ddu)*drhobardxu+grav*rhobaru*detadxu
  !dppdyu=dpsdyu+grav*sig*(etau+ddu)*drhobardyu+grav*rhobaru*detadyu
  !dppdxv=dpsdxv+grav*sig*(etav+ddv)*drhobardxv+grav*rhobarv*detadxv
  !dppdyv=dpsdyv+grav*sig*(etav+ddv)*drhobardyv+grav*rhobarv*detadyv

  ! Create arrays for u and v at t+1 in terms of neta gradients
    
  !nu=kku+llu*etau+mmu*detadxu+nnu*detadyu (staggered)
  !nv=kkv+llv*etav+mmv*detadyv+nnv*detadxv (staggered)

  if (usetide.eq.1) then
    llu(:,ii)=(bu*drhobardxu(:,ii)+cu*drhobardyu(:,ii))*grav*gosig(ii)
    mmu(:,ii)=bu*grav*(rhobaru+rhou*(1.-sal)*2./(1.+eps))
    nnu(:,ii)=cu*grav*(rhobaru+rhou*(1.-sal)*2./(1.+eps))
    kku(:,ii)=au+bu*((dpsdxu+grav*rhou*dttdxu)*2./(1.+eps)+grav*drhobardxu(:,ii)*gosig(ii)*ddu(1:ifull)) &
                +cu*((dpsdyu+grav*rhou*dttdyu)*2./(1.+eps)+grav*drhobardyu(:,ii)*gosig(ii)*ddu(1:ifull))

    llv(:,ii)=(bv*drhobardyv(:,ii)+cv*drhobardxv(:,ii))*grav*gosig(ii)
    mmv(:,ii)=bv*grav*(rhobarv+rhov*(1.-sal)*2./(1.+eps))
    nnv(:,ii)=cv*grav*(rhobarv+rhov*(1.-sal)*2./(1.+eps))
    kkv(:,ii)=av+bv*((dpsdyv+grav*rhov*dttdyv)*2./(1.+eps)+grav*drhobardyv(:,ii)*gosig(ii)*ddv(1:ifull)) &
                +cv*((dpsdxv+grav*rhov*dttdxv)*2./(1.+eps)+grav*drhobardxv(:,ii)*gosig(ii)*ddv(1:ifull))
  else
    llu(:,ii)=(bu*drhobardxu(:,ii)+cu*drhobardyu(:,ii))*grav*gosig(ii)
    mmu(:,ii)=bu*grav*rhobaru
    nnu(:,ii)=cu*grav*rhobaru
    kku(:,ii)=au+bu*(dpsdxu*2./(1.+eps)+grav*drhobardxu(:,ii)*gosig(ii)*ddu(1:ifull)) &
                +cu*(dpsdyu*2./(1.+eps)+grav*drhobardyu(:,ii)*gosig(ii)*ddu(1:ifull))

    llv(:,ii)=(bv*drhobardyv(:,ii)+cv*drhobardxv(:,ii))*grav*gosig(ii)
    mmv(:,ii)=bv*grav*rhobarv
    nnv(:,ii)=cv*grav*rhobarv
    kkv(:,ii)=av+bv*(dpsdyv*2./(1.+eps)+grav*drhobardyv(:,ii)*gosig(ii)*ddv(1:ifull)) &
                +cv*(dpsdxv*2./(1.+eps)+grav*drhobardxv(:,ii)*gosig(ii)*ddv(1:ifull))
  end if

  llu(:,ii)=llu(:,ii)*eeu(1:ifull)
  mmu(:,ii)=mmu(:,ii)*eeu(1:ifull)
  nnu(:,ii)=nnu(:,ii)*eeu(1:ifull)
  kku(:,ii)=kku(:,ii)*eeu(1:ifull)

  llv(:,ii)=llv(:,ii)*eev(1:ifull)
  mmv(:,ii)=mmv(:,ii)*eev(1:ifull)
  nnv(:,ii)=nnv(:,ii)*eev(1:ifull)
  kkv(:,ii)=kkv(:,ii)*eev(1:ifull)

  ! Pre-integrate arrays for u and v at t+1 (i.e., for calculating net divergence at t+1)

  !int nu dz = sou+spu*etau+squ*detadxu+sru*detadyu
  !int nv dz = sov+spv*etav+sqv*detadyv+srv*detadxv

  sou(1:ifull)=sou(1:ifull)+kku(:,ii)*godsig(ii)
  spu(1:ifull)=spu(1:ifull)+llu(:,ii)*godsig(ii)
  squ(1:ifull)=squ(1:ifull)+mmu(:,ii)*godsig(ii)
  sru(1:ifull)=sru(1:ifull)+nnu(:,ii)*godsig(ii)

  sov(1:ifull)=sov(1:ifull)+kkv(:,ii)*godsig(ii)
  spv(1:ifull)=spv(1:ifull)+llv(:,ii)*godsig(ii)
  sqv(1:ifull)=sqv(1:ifull)+mmv(:,ii)*godsig(ii)
  srv(1:ifull)=srv(1:ifull)+nnv(:,ii)*godsig(ii)

end do

! calculate terms for ice velocity at t+1

! (staggered)
! niu(t+1) = niu + ibu*dipdx + icu*dipdy
! niv(t+1) = niv + ibv*dipdy + icv*dipdx

imu=0.5*(imass(1:ifull)+imass(ie))
imv=0.5*(imass(1:ifull)+imass(in))
! note missing 0.5 as ip is the average of t and t+1
ibu(1:ifull)=-dt/(imu*(1.+(1.+eps)*(1.+eps)*0.25*dt*dt*fu(1:ifull)*fu(1:ifull)))*eeu(1:ifull)
ibv(1:ifull)=-dt/(imv*(1.+(1.+eps)*(1.+eps)*0.25*dt*dt*fv(1:ifull)*fv(1:ifull)))*eev(1:ifull)
icu(1:ifull)= dt*fu(1:ifull)*ibu(1:ifull)
icv(1:ifull)=-dt*fv(1:ifull)*ibv(1:ifull)

dumc(1:ifull,1)=sou(1:ifull)
dumd(1:ifull,1)=sov(1:ifull)
dumc(1:ifull,2)=spu(1:ifull)
dumd(1:ifull,2)=spv(1:ifull)
dumc(1:ifull,3)=squ(1:ifull)
dumd(1:ifull,3)=sqv(1:ifull)
dumc(1:ifull,4)=sru(1:ifull)
dumd(1:ifull,4)=srv(1:ifull)
dumc(1:ifull,5)=niu(1:ifull)
dumd(1:ifull,5)=niv(1:ifull)
dumc(1:ifull,6)=ibu(1:ifull)
dumd(1:ifull,6)=ibv(1:ifull)
dumc(1:ifull,7)=icu(1:ifull)
dumd(1:ifull,7)=icv(1:ifull)
call boundsuv(dumc(:,1:7),dumd(:,1:7))
sou=dumc(:,1)
sov=dumd(:,1)
spu=dumc(:,2)
spv=dumd(:,2)
squ=dumc(:,3)
sqv=dumd(:,3)
sru=dumc(:,4)
srv=dumd(:,4)
niu=dumc(:,5)
niv=dumd(:,5)
ibu=dumc(:,6)
ibv=dumd(:,6)
icu=dumc(:,7)
icv=dumd(:,7)

! prep gradient terms
odiv=(sou(1:ifull)/emu(1:ifull)-sou(iwu)/emu(iwu)  &
     +sov(1:ifull)/emv(1:ifull)-sov(isv)/emv(isv)) &
     *em(1:ifull)*em(1:ifull)/ds

odivb=(sou(1:ifull)*ddu(1:ifull)/emu(1:ifull)-sou(iwu)*ddu(iwu)/emu(iwu)  &
      +sov(1:ifull)*ddv(1:ifull)/emv(1:ifull)-sov(isv)*ddv(isv)/emv(isv)) &
      *em(1:ifull)*em(1:ifull)/ds

sue=spu(1:ifull)*0.5/emu(1:ifull)-squ(1:ifull)/ds
suw=spu(iwu)*0.5/emu(iwu)        +squ(iwu)/ds
svn=spv(1:ifull)*0.5/emv(1:ifull)-sqv(1:ifull)/ds
svs=spv(isv)*0.5/emv(isv)        +sqv(isv)/ds
sdiv=(sue-suw+svn-svs)*em(1:ifull)*em(1:ifull)/ds

sue=(spu(1:ifull)*0.5/emu(1:ifull)-squ(1:ifull)/ds)*ddu(1:ifull)
suw=(spu(iwu)*0.5/emu(iwu)        +squ(iwu)/ds    )*ddu(iwu)
svn=(spv(1:ifull)*0.5/emv(1:ifull)-sqv(1:ifull)/ds)*ddv(1:ifull)
svs=(spv(isv)*0.5/emv(isv)        +sqv(isv)/ds    )*ddv(isv)
sdivb=(sue-suw+svn-svs)*em(1:ifull)*em(1:ifull)/ds

sue=spu(1:ifull)*0.5/emu(1:ifull)+squ(1:ifull)/ds
suw=spu(iwu)*0.5/emu(iwu)        -squ(iwu)/ds
svn=spv(1:ifull)*0.5/emv(1:ifull)+sqv(1:ifull)/ds
svs=spv(isv)*0.5/emv(isv)        -sqv(isv)/ds

! Iteratively solve for free surface height, eta
! Here we use SOR due to the non-linear equation for eta.
alpha=0.9
do ll=1,llmax

  ! 9-point version -----------------------------------------------

  call bounds(neta,corner=.true.)
  snu(1:ifull)=sru(1:ifull)*stwgt(1:ifull,1)*0.25*(neta(in)+neta(ine)-neta(is)-neta(ise))/ds
  snv(1:ifull)=srv(1:ifull)*stwgt(1:ifull,2)*0.25*(neta(ie)+neta(ien)-neta(iw)-neta(iwn))/ds
  snuw=sru(iwu)*stwgt(iwu,1)*0.25*(neta(inw)+neta(in)-neta(isw)-neta(is))/ds
  snvs=srv(isv)*stwgt(isv,2)*0.25*(neta(ies)+neta(ie)-neta(iws)-neta(iw))/ds
  ! For now, assume Boussinesq fluid and treat density in continuity equation as constant
  div=(snu(1:ifull)+sue*neta(ie)-snuw-suw*neta(iw)  &
      +snv(1:ifull)+svn*neta(in)-snvs-svs*neta(is)) &
      *em(1:ifull)*em(1:ifull)/ds
  divb=((snu(1:ifull)+sue*neta(ie))*ddu(1:ifull)-(snuw+suw*neta(iw))*ddu(iwu)  &
       +(snv(1:ifull)+svn*neta(in))*ddv(1:ifull)-(snvs+svs*neta(is))*ddv(isv)) &
       *em(1:ifull)*em(1:ifull)/ds

  ! solve for quadratic expression of neta^(t+1)
  ! div^(t+1)=(div+odiv+sdiv*neta)*neta+(divb+odivb+sdivb*neta)    
  au=-(1.+eps)*0.5*dt*sdiv
  bu=-(1.+(1.+eps)*0.5*dt*(div+odiv+sdivb))
  cu=xps-(1.+eps)*0.5*dt*(divb+odivb)
  where (abs(au).gt.1.E-4)
    seta=-neta(1:ifull)+0.5*(-bu-sqrt(bu*bu-4.*au*cu))/au
  elsewhere
    ! the following is a Talyor expansion of the above expression
    ! and should be valid for au<1.E-3
    seta=-neta(1:ifull)-cu/bu-au*cu*cu/(bu**3) !-2.*au**2*cu**3/(bu**5)+...
  end where

  ! The following expression limits the minimum depth to 1m
  ! (should not occur for typical eta values)
  seta=max(seta,min(mindep-dd(1:ifull)-neta(1:ifull),0.)) ! this should become a land point
  where (.not.wtr(1:ifull))
    seta=0.
  end where
  neta(1:ifull)=alpha*seta+neta(1:ifull)
  
  ! Break iterative loop when maximum error is below tol (expensive)
  maxloclseta=maxval(abs(seta))
  call MPI_AllReduce(maxloclseta,maxglobseta,1,MPI_REAL,MPI_MAX,MPI_COMM_WORLD,ierr)
  if (maxglobseta.lt.tol.and.ll.gt.2) exit

  totits=totits+1
end do

if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: free surface conservation"
end if

! volume conservation for water ---------------------------------------
if (nud_sfh==0) then
  odum=0.
  where (wtr(1:ifull))
    !odum=neta(1:ifull)-w_e
    odum=neta(1:ifull) ! assume no change in global sea level
  end where
  call ccglobal_posneg(odum,delpos,delneg)
  alph_p = -delneg/max(delpos,1.E-20)
  alph_p = min(max(sqrt(alph_p),1.E-20),1.E20)
  !neta(1:ifull)=w_e+max(0.,odum)*alph_p+min(0.,odum)/alph_p
  neta(1:ifull)=max(0.,odum)*alph_p+min(0.,odum)/alph_p
end if

if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: update currents"
end if

call bounds(neta,corner=.true.)
oeu(1:ifull)=0.5*(neta(1:ifull)+neta(ie))
oev(1:ifull)=0.5*(neta(1:ifull)+neta(in))
tnu=0.5*(neta(in)+neta(ine))
tsu=0.5*(neta(is)+neta(ise))
tev=0.5*(neta(ie)+neta(ien))
twv=0.5*(neta(iw)+neta(iwn))
detadxu=(neta(ie)-neta(1:ifull))*emu(1:ifull)/ds
detadyu=stwgt(1:ifull,1)*0.5*(tnu-tsu)*emu(1:ifull)/ds
detadxv=stwgt(1:ifull,2)*0.5*(tev-twv)*emv(1:ifull)/ds
detadyv=(neta(in)-neta(1:ifull))*emv(1:ifull)/ds

! Update currents once neta is calculated
do ii=1,wlev
  ! update currents (staggered)
  nu(1:ifull,ii)=kku(:,ii)+llu(:,ii)*oeu(1:ifull)+mmu(:,ii)*detadxu+nnu(:,ii)*detadyu
  nv(1:ifull,ii)=kkv(:,ii)+llv(:,ii)*oev(1:ifull)+mmv(:,ii)*detadyv+nnv(:,ii)*detadxv
end do

! use nu and nv for unstagged currents
dumt=nu(1:ifull,:)
dums=nv(1:ifull,:)
call mlounstaguv(dumt,dums,uau,uav)
nu(1:ifull,:)=uau
nv(1:ifull,:)=uav

! UPDATE ICE DYNAMICS ---------------------------------------------
! Here we start by calculating the ice velocity and then advecting
! the various ice prognostic variables.

if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: Ice fluid dynamics"
end if

! Update ice velocities
! Average free surface over t and t+1
tau(:,1)=grav*0.5*((1.-eps)*(oeta(ie)-oeta(1:ifull))+(1.+eps)*(neta(ie)-neta(1:ifull)))*emu(1:ifull)/ds ! staggered
tav(:,1)=grav*0.5*((1.-eps)*(oeta(in)-oeta(1:ifull))+(1.+eps)*(neta(in)-neta(1:ifull)))*emv(1:ifull)/ds
call mlounstaguv(tau(:,1:1),tav(:,1:1),siu,siv) ! trick from JLM
snu(1:ifull)=i_u+(1.-eps)*0.5*dt*f(1:ifull)*i_v-dt*siu(:,1)
snv(1:ifull)=i_v-(1.-eps)*0.5*dt*f(1:ifull)*i_u-dt*siv(:,1)
uiu(:,1)=snu(1:ifull)+(1.+eps)*0.5*dt*f(1:ifull)*snv(1:ifull) ! unstaggered
uiv(:,1)=snv(1:ifull)-(1.+eps)*0.5*dt*f(1:ifull)*snu(1:ifull)
call mlostaguv(uiu,uiv,siu,siv)
! niu and niv hold the free drift solution (staggered).  Wind stress terms are updated in mlo.f90
niu(1:ifull)=siu(:,1)/(1.+(1.+eps)*(1.+eps)*0.25*dt*dt*fu(1:ifull)*fu(1:ifull))*eeu(1:ifull) ! staggered
niv(1:ifull)=siv(:,1)/(1.+(1.+eps)*(1.+eps)*0.25*dt*dt*fv(1:ifull)*fv(1:ifull))*eev(1:ifull)

! maximum pressure for cavitating fluid
ipmax=27500.*ndic(1:ifull)*exp(-20.*(1.-nfracice(1:ifull)))

! Iterative loop to estimate ice 'pressure'
odum=ibu(1:ifull)+ibu(iwu)+ibv(1:ifull)+ibv(isv)
alpha=0.9
do ll=1,llmax

  !dipdxu=(ip(ie)-ip(1:ifull))*emu(1:ifull)/ds
  !dipdyu=spu(1:ifull)*emu(1:ifull)/(ds*icu(1:ifull))
  !dipdxv=spv(1:ifull)*emv(1:ifull)/(ds*icv(1:ifull))
  !dipdyv=(ip(in)-ip(1:ifull))*emv(1:ifull)/ds

  !snu(1:ifull)=niu(1:ifull)+ibu*dipdxu+icu*dipdyu
  !snv(1:ifull)=niv(1:ifull)+ibv*dipdyv+icv*dipdxv
  !call boundsuv(snu,snv)
    
  ! new divergence at t+1
  !div=(snu(1:ifull)/emu(1:ifull)-snu(iwu)/emu(iwu)+snv(1:ifull)/emv(1:ifull)-snv(isv)/emv(isv)) &
  !    *em(1:ifull)*em(1:ifull)/ds

  
  ! 9-point version -------------------------------------------------
  
  call bounds(ipice,corner=.true.)
  snu(1:ifull)=0.25*stwgt(1:ifull,1)*icu(1:ifull)*(ipice(in)+ipice(ine)-ipice(is)-ipice(ise))
  snv(1:ifull)=0.25*stwgt(1:ifull,2)*icv(1:ifull)*(ipice(ie)+ipice(ien)-ipice(iw)-ipice(iwn))
  snuw=0.25*stwgt(iwu,1)*icu(iwu)*(ipice(inw)+ipice(in)-ipice(isw)-ipice(is))
  snvs=0.25*stwgt(isv,2)*icv(isv)*(ipice(ies)+ipice(ie)-ipice(iws)-ipice(iw))

  ! update ice pressure to remove negative divergence
  ! (assume change in imass is small)
  where (odum.ne.0..and.sicedep.gt.0.01)
    nip=((niu(1:ifull)/emu(1:ifull)-niu(iwu)/emu(iwu))*ds    &
        +ibu(1:ifull)*ipice(ie)+ibu(iwu)*ipice(iw)           &
        +snu(1:ifull)-snuw                                   &
        +(niv(1:ifull)/emv(1:ifull)-niv(isv)/emv(isv))*ds    &          
        +ibv(1:ifull)*ipice(in)+ibv(isv)*ipice(is)           &
        +snv(1:ifull)-snvs)                                  &
       /odum
  elsewhere
    nip=0.
  end where

  select case(icemode)
    case(2)
      ! cavitating fluid
      nip=max(min(nip,ipmax),0.)
    case(1)
      ! incompressible fluid
      nip=max(nip,0.)
    case DEFAULT
      ! free drift
      nip=0.
  end select
  maxloclip=maxval(abs(nip-ipice(1:ifull)))
  ipice(1:ifull)=alpha*nip+(1.-alpha)*ipice(1:ifull)

  call MPI_AllReduce(maxloclip,maxglobip,1,MPI_REAL,MPI_MAX,MPI_COMM_WORLD,ierr)
  if (maxglobip.lt.itol.and.ll.gt.2) exit

  itotits=itotits+1
end do

! Update ice velocity with internal pressure terms
call bounds(ipice,corner=.true.)
tnu=0.5*(ipice(in)+ipice(ine))
tsu=0.5*(ipice(is)+ipice(ise))
tev=0.5*(ipice(ie)+ipice(ien))
twv=0.5*(ipice(iw)+ipice(iwn))
dipdxu=(ipice(ie)-ipice(1:ifull))*emu(1:ifull)/ds
dipdyu=stwgt(1:ifull,1)*0.5*(tnu-tsu)*emu(1:ifull)/ds
dipdxv=stwgt(1:ifull,2)*0.5*(tev-twv)*emv(1:ifull)/ds
dipdyv=(ipice(in)-ipice(1:ifull))*emv(1:ifull)/ds
niu(1:ifull)=(niu(1:ifull)+ibu(1:ifull)*dipdxu+icu(1:ifull)*dipdyu)*eeu(1:ifull)
niv(1:ifull)=(niv(1:ifull)+ibv(1:ifull)*dipdyv+icv(1:ifull)*dipdxv)*eev(1:ifull)
call boundsuv(niu,niv)

! Normalisation factor for conserving ice flow in and out of gridbox
spnet(1:ifull)=-min(niu(iwu),0.)+max(niu(1:ifull),0.)-min(niv(isv),0.)+max(niv(1:ifull),0.)

! ADVECT ICE ------------------------------------------------------
! use simple upwind scheme

if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: Ice advection"
end if

! Horizontal advection for ice area
dumc(1:ifull,1)=fracice/(em(1:ifull)*em(1:ifull)) ! ndum is an area
! Horizontal advection for ice volume
dumc(1:ifull,2)=sicedep*fracice/(em(1:ifull)*em(1:ifull)) ! ndum is a volume
! Horizontal advection for snow volume
dumc(1:ifull,3)=snowd*0.001*fracice/(em(1:ifull)*em(1:ifull)) ! now ndum is a volume
! Conservation
dumc(1:ifull,4)=spnet(1:ifull)
call bounds(dumc(:,1:4))
spnet=dumc(:,4)
do ii=1,3
  call upwindadv(dumc(:,ii),niu,niv,spnet)
end do  
nfracice(1:ifull)=dumc(1:ifull,1)*em(1:ifull)*em(1:ifull)
nfracice(1:ifull)=min(max(nfracice(1:ifull),0.),1.)
ndic(1:ifull)=dumc(1:ifull,2)*em(1:ifull)*em(1:ifull)/max(nfracice(1:ifull),1.E-10)
ndsn(1:ifull)=dumc(1:ifull,3)*em(1:ifull)*em(1:ifull)/max(nfracice(1:ifull),1.E-10)

! Horizontal advection for ice energy store
dumc(1:ifull,1)=i_sto*fracice/(em(1:ifull)*em(1:ifull))
! Horizontal advection for ice salinity
dumc(1:ifull,2)=i_sal*fracice*sicedep/(em(1:ifull)*em(1:ifull))
call bounds(dumc(:,1:2))
do ii=1,2
  call upwindadv(dumc(:,ii),niu,niv,spnet)
end do
nsto(1:ifull)=dumc(1:ifull,1)*em(1:ifull)*em(1:ifull)/max(nfracice(1:ifull),1.E-10)
nis(1:ifull)=dumc(1:ifull,2)*em(1:ifull)*em(1:ifull)/max(ndic(1:ifull)*nfracice(1:ifull),1.E-10)

! Horizontal advection for surface temperature
dumc(1:ifull,1)=i_it(1:ifull,1)*fracice/(em(1:ifull)*em(1:ifull))
! Horizontal advection of snow temperature
dumc(1:ifull,2)=i_it(1:ifull,2)*fracice*snowd*0.001/(em(1:ifull)*em(1:ifull))
! Horizontal advection of ice temperature
do ii=3,4
  dumc(1:ifull,ii)=i_it(1:ifull,ii)*fracice*sicedep/(em(1:ifull)*em(1:ifull))
end do
call bounds(dumc(:,1:4))
do ii=1,4
  call upwindadv(dumc(:,ii),niu,niv,spnet)
end do
nit(1:ifull,1)=dumc(1:ifull,1)*em(1:ifull)*em(1:ifull)/max(nfracice(1:ifull),1.E-10)
nit(1:ifull,2)=dumc(1:ifull,2)*em(1:ifull)*em(1:ifull)/max(ndsn(1:ifull)*nfracice(1:ifull),1.E-10)
do ii=3,4
  nit(1:ifull,ii)=dumc(1:ifull,ii)*em(1:ifull)*em(1:ifull)/max(ndic(1:ifull)*nfracice(1:ifull),1.E-10)
end do

! repair problems found after advection of ice
where (nfracice(1:ifull).lt.1.E-4)
  nfracice(1:ifull)=0.
  ndic(1:ifull)=0.
  ndsn(1:ifull)=0.
  nsto(1:ifull)=0.
  nis(1:ifull)=0.
  nit(1:ifull,1)=w_t(:,1)
  nit(1:ifull,2)=w_t(:,1)
  nit(1:ifull,3)=w_t(:,1)
  nit(1:ifull,4)=w_t(:,1)
end where
  
where (ndsn(1:ifull).lt.1.E-3)
  nit(1:ifull,2)=nit(1:ifull,3)
end where

! bad data patch
if (any(nit(1:ifull,:).lt.160.)) then
  write(6,*) "WARN: Bad ice data patch"
end if
do ii=1,4
  where(nit(1:ifull,ii).lt.160.)
    nit(1:ifull,1)=w_t(:,1)
    nit(1:ifull,2)=w_t(:,1)
    nit(1:ifull,3)=w_t(:,1)
    nit(1:ifull,4)=w_t(:,1)  
  end where
end do

! unstagger ice velocities
siu(:,1)=niu(1:ifull)
siv(:,1)=niv(1:ifull)
call mlounstaguv(siu,siv,sju,sjv)
niu(1:ifull)=sju(:,1)
niv(1:ifull)=sjv(:,1)

if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: conserve salinity"
end if
  
! salinity conservation
if (nud_sss==0) then
  delpos=0.
  delneg=0.
  dum=0.
  ndum(1:ifull)=sum(w_s(1:ifull,:),2)
  do ii=1,wlev
    where(wtr(1:ifull).and.ndum(1:ifull)>0.1)
      !dum(:,ii)=ns(1:ifull,ii)-w_s
      dum(:,ii)=ns(1:ifull,ii)-34.72 ! assume no change in global salinity
    end where
    odum=dum(:,ii)
    ! cannot use 3d version, since it is hardwired to atmosphere dsig
    call ccglobal_posneg(odum,dumpp,dumpn)
    delpos=delpos+dumpp*godsig(ii)
    delneg=delneg+dumpn*godsig(ii)
  end do
  call ccglobal_posneg(odum,delpos,delneg)
  alph_p = -delneg/max(delpos,1.E-20)
  alph_p = min(sqrt(alph_p),alph_p)
  do ii=1,wlev
    where(wtr(1:ifull).and.ndum(1:ifull)>0.1)
      !ns(1:ifull,ii)=w_s+max(0.,dum(:,ii))*alph_p+min(0.,dum(:,ii))/max(1.,alph_p)    
      ns(1:ifull,ii)=34.72+max(0.,dum(:,ii))*alph_p+min(0.,dum(:,ii))/max(1.,alph_p)
    end where
  end do
end if

if (myid==0.and.(ktau<=100.or.maxglobseta>tol.or.maxglobip>itol)) then
  write(6,*) "MLODYNAMICS ",totits,maxglobseta,itotits,maxglobip
end if

if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: Export"
end if

do ii=1,wlev
  call mloimport(0,nt(1:ifull,ii),ii,0)
  call mloimport(1,ns(1:ifull,ii),ii,0)
  call mloimport(2,nu(1:ifull,ii),ii,0)
  call mloimport(3,nv(1:ifull,ii),ii,0)
end do
call mloimport(4,neta(1:ifull),0,0)
do ii=1,4
  call mloimpice(nit(1:ifull,ii),ii,0)
end do
call mloimpice(nfracice(1:ifull),5,0)
call mloimpice(ndic(1:ifull),6,0)
call mloimpice(ndsn(1:ifull),7,0)
call mloimpice(nsto(1:ifull),8,0)
call mloimpice(niu(1:ifull),9,0)
call mloimpice(niv(1:ifull),10,0)
call mloimpice(nis(1:ifull),11,0)
where (wtr(1:ifull))
  fracice=nfracice(1:ifull)
  sicedep=ndic(1:ifull)
  snowd=ndsn(1:ifull)*1000.
end where

if (myid==0.and.nmaxpr==1) then
  write(6,*) "mlohadv: Finish"
end if

return
end subroutine mlohadv

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Calculate depature points for MLO semi-Lagrangian advection
! (This subroutine is based on depts.f)

subroutine mlodeps(ubar,vbar,nface,xg,yg,x3d,y3d,z3d,wtr)

use cc_mpi
use mlo
use vecsuv_m
use xyzinfo_m

implicit none

include 'newmpar.h'
include 'const_phys.h'
include 'parm.h'

integer ii,n,kx
integer, dimension(:,:), intent(out) :: nface
real, dimension(ifull,size(nface,2)), intent(in) :: ubar,vbar
real, dimension(ifull,size(nface,2)), intent(out) :: xg,yg
real*8, dimension(ifull,size(nface,2)), intent(out) :: x3d,y3d,z3d
real, dimension(ifull,size(nface,2)) :: uc,vc,wc
real, dimension(ifull+iextra,size(nface,2)) :: temp
logical, dimension(ifull+iextra), intent(in) :: wtr
integer, parameter :: nguess = 2

kx=size(nface,2)

! departure point x, y, z is called x3d, y3d, z3d
! first find corresponding cartesian vels
do ii=1,kx
  uc(:,ii)=(ax(1:ifull)*ubar(:,ii)+bx(1:ifull)*vbar(:,ii))*dt/rearth ! unit sphere 
  vc(:,ii)=(ay(1:ifull)*ubar(:,ii)+by(1:ifull)*vbar(:,ii))*dt/rearth ! unit sphere 
  wc(:,ii)=(az(1:ifull)*ubar(:,ii)+bz(1:ifull)*vbar(:,ii))*dt/rearth ! unit sphere 
  x3d(:,ii)=x-uc(:,ii) ! 1st guess
  y3d(:,ii)=y-vc(:,ii)
  z3d(:,ii)=z-wc(:,ii)
end do

! convert to grid point numbering
do ii=1,kx
  call mlotoij5(x3d(:,ii),y3d(:,ii),z3d(:,ii),nface(:,ii),xg(:,ii),yg(:,ii))
end do
! Share off processor departure points.
call deptsync(nface,xg,yg)

do n=1,nguess
  temp(1:ifull,:) = uc
  call mlob2ints(temp,nface,xg,yg,wtr)
  do ii=1,kx
    x3d(:,ii) = x - 0.5*(uc(:,ii)+temp(1:ifull,ii)) ! n+1 guess
  end do
  temp(1:ifull,:) = vc
  call mlob2ints(temp,nface,xg,yg,wtr)
  do ii=1,kx
    y3d(:,ii) = y - 0.5*(vc(:,ii)+temp(1:ifull,ii)) ! n+1 guess
  end do
  temp(1:ifull,:) = wc
  call mlob2ints(temp,nface,xg,yg,wtr)
  do ii=1,kx
    z3d(:,ii) = z - 0.5*(wc(:,ii)+temp(1:ifull,ii)) ! n+1 guess
  end do
  do ii=1,kx
    call mlotoij5(x3d(:,ii),y3d(:,ii),z3d(:,ii),nface(:,ii),xg(:,ii),yg(:,ii))
  end do
  !     Share off processor departure points.
  call deptsync(nface,xg,yg)
end do

return
end subroutine mlodeps

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Calculate indices
! This code is from depts.f

subroutine mlotoij5(x3d,y3d,z3d,nface,xg,yg)

use bigxy4_m
use cc_mpi
use xyzinfo_m

implicit none

include 'newmpar.h'
include 'parm.h'
include 'parmgeom.h'

integer loop,iq,i,j,is,js
integer, dimension(ifull), intent(out) :: nface
real, dimension(ifull), intent(out) :: xg,yg
real, dimension(ifull) :: xstr,ystr,zstr
real, dimension(ifull) :: denxyz,xd,yd,zd
real, dimension(ifull) :: ri,rj
real dxx,dxy,dyx,dyy
real*8, dimension(ifull), intent(inout) :: x3d,y3d,z3d
real*8, dimension(ifull) :: den
real*8 alf,alfonsch
real*8, parameter :: one = 1.
integer, parameter :: nmaploop = 3

!     if necessary, transform (x3d, y3d, z3d) to equivalent
!     coordinates (xstr, ystr, zstr) on regular gnomonic panels
if(schmidt.eq.1.)then
   xstr=x3d
   ystr=y3d
   zstr=z3d
else      ! (schmidt.ne.1.)
   alf=(one-schmidt**2)/(one+schmidt**2)
   alfonsch=2.*schmidt/(one+schmidt**2)  ! same but bit more accurate
   den=one-alf*z3d ! to force real*8
   xstr=x3d*(alfonsch/den)
   ystr=y3d*(alfonsch/den)
   zstr=    (z3d-alf)/den
endif     ! (schmidt.ne.1.)

!      first deduce departure faces
!      instead calculate cubic coordinates
!      The faces are:
!      0: X=1   1: Z=1   2: Y=1   3: X=-1   4: Z=-1   5: Y=-1
denxyz=max( abs(xstr),abs(ystr),abs(zstr) )
xd=xstr/denxyz
yd=ystr/denxyz
zd=zstr/denxyz

where (abs(xstr-denxyz).lt.1.E-6)
  nface(:)    =0
  xg(:) =      yd
  yg(:) =      zd
elsewhere (abs(xstr+denxyz).lt.1.E-6)
  nface(:)    =3
  xg(:) =     -zd
  yg(:) =     -yd
elsewhere (abs(zstr-denxyz).lt.1.E-6)
  nface(:)    =1
  xg(:) =      yd
  yg(:) =     -xd
elsewhere (abs(zstr+denxyz).lt.1.E-6)
  nface(:)    =4
  xg(:) =      xd
  yg(:) =     -yd
elsewhere (abs(ystr-denxyz).lt.1.E-6)
  nface(:)    =2
  xg(:) =     -zd
  yg(:) =     -xd
elsewhere
  nface(:)    =5
  xg(:) =      xd
  yg(:) =      zd
end where

!     use 4* resolution grid il --> 4*il
xg=min(max(-.99999,xg),.99999)
yg=min(max(-.99999,yg),.99999)
!      first guess for ri, rj and nearest i,j
ri=1.+(1.+xg)*2.*real(il_g)
rj=1.+(1.+yg)*2.*real(il_g)
do loop=1,nmaploop
  do iq=1,ifull
    i=nint(ri(iq))
    j=nint(rj(iq))
    is=nint(sign(1.,ri(iq)-real(i)))
    js=nint(sign(1.,rj(iq)-real(j)))
!       predict new value for ri, rj
    dxx=xx4(i+is,j)-xx4(i,j)
    dyx=xx4(i,j+js)-xx4(i,j)
    dxy=yy4(i+is,j)-yy4(i,j)
    dyy=yy4(i,j+js)-yy4(i,j)       
    den(iq)=dxx*dyy-dyx*dxy
    ri(iq)=real(i)+real(is)*((xg(iq)-xx4(i,j))*dyy-(yg(iq)-yy4(i,j))*dyx)/den(iq)
    rj(iq)=real(j)+real(js)*((yg(iq)-yy4(i,j))*dxx-(xg(iq)-xx4(i,j))*dxy)/den(iq)
  end do
enddo  ! loop loop
!      expect xg, yg to range between .5 and il+.5
xg=.25*(ri+3.) -.5  ! -.5 for stag; back to normal ri, rj defn
yg=.25*(rj+3.) -.5  ! -.5 for stag

return
end subroutine mlotoij5

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Interpolate depature points for semi-Lagrangian advection
! This code is from ints.f

! This version is for velocity as the interpolated value is zero over land
! We use bi-cubic based on JLM's ints.f routines
subroutine mlob2ints(s,nface,xg,yg,wtr)

use cc_mpi
use indices_m
use mlo

implicit none

include 'newmpar.h'
include 'parm.h'
include 'parmhor.h'
include 'mpif.h'

integer idel,iq,jdel,kx
integer i,j,k,n,ind,ip,jp,iproc,ierr,intsch,ncount
integer, dimension(:,:), intent(in) :: nface
real, dimension(ifull,size(nface,2)), intent(in) :: xg,yg
real, dimension(ifull+iextra,size(nface,2)), intent(inout) :: s
real, dimension(-1:ipan+2,-1:jpan+2,1:npan,size(nface,2)) :: sx
real, dimension(-1:2,-1:2) :: sc
real, dimension(4) :: r
real xxg,yyg,aab,aac,aad,cxx
logical, dimension(ifull+iextra), intent(in) :: wtr
ind(i,j,n)=i+(j-1)*ipan+(n-1)*ipan*jpan  ! *** for n=1,npan

kx=size(nface,2)
intsch=mod(ktau,2)
cxx=-999.
sx=cxx
sc=cxx

do iq=1,ifull
  if(.not.wtr(iq)) then
    s(iq,:)=cxx
  end if
end do
call bounds(s,nrows=2)

!======================== start of intsch=1 section ====================
if(intsch==1)then

  do n=1,npan         ! first simple copy into larger array
    do j=1,jpan
      do i=1,ipan
        sx(i,j,n,:) = s(ind(i,j,n),:)
      end do         ! i loop
      sx(0,j,n,:)      = s(iw(ind(1,j,n)),:)
      sx(-1,j,n,:)     = s(iww(ind(1,j,n)),:)
      sx(ipan+1,j,n,:) = s(ie(ind(ipan,j,n)),:)
      sx(ipan+2,j,n,:) = s(iee(ind(ipan,j,n)),:)
    end do            ! j loop
    do i=1,ipan
      sx(i,0,n,:)      = s(is(ind(i,1,n)),:)
      sx(i,-1,n,:)     = s(iss(ind(i,1,n)),:)
      sx(i,jpan+1,n,:) = s(in(ind(i,jpan,n)),:)
      sx(i,jpan+2,n,:) = s(inn(ind(i,jpan,n)),:)
    end do            ! i loop
!   for ew interpolation, sometimes need (different from ns):
!       (-1,0),   (0,0),   (0,-1)   (-1,il+1),   (0,il+1),   (0,il+2)
!     (il+1,0),(il+2,0),(il+1,-1) (il+1,il+1),(il+2,il+1),(il+1,il+2)

    sx(-1,0,n,:)          = s(lwws(n),:)
    sx(0,0,n,:)           = s(iws(ind(1,1,n)),:)
    sx(0,-1,n,:)          = s(lwss(n),:)
    sx(ipan+1,0,n,:)      = s(ies(ind(ipan,1,n)),:)
    sx(ipan+2,0,n,:)      = s(lees(n),:)
    sx(ipan+1,-1,n,:)     = s(less(n),:)
    sx(-1,jpan+1,n,:)     = s(lwwn(n),:)
    sx(0,jpan+2,n,:)      = s(lwnn(n),:)
    sx(ipan+2,jpan+1,n,:) = s(leen(n),:)
    sx(ipan+1,jpan+2,n,:) = s(lenn(n),:)
    sx(0,jpan+1,n,:)      = s(iwn(ind(1,jpan,n)),:)
    sx(ipan+1,jpan+1,n,:) = s(ien(ind(ipan,jpan,n)),:)
    !sx(-1,0,n,:)          = s(iww(ind(1,1,n)),:)
    !sx(0,0,n,:)           = 0.5*(s(iw(ind(1,1,n)),:)+s(is(ind(1,1,n)),:))
    !sx(0,-1,n,:)          = s(iss(ind(1,1,n)),:)
    !sx(ipan+1,0,n,:)      = 0.5*(s(ie(ind(ipan,1,n)),:)+s(is(ind(ipan,1,n)),:))
    !sx(ipan+2,0,n,:)      = s(iee(ind(ipan,1,n)),:)
    !sx(ipan+1,-1,n,:)     = s(iss(ind(ipan,1,n)),:)
    !sx(-1,jpan+1,n,:)     = s(iww(ind(1,jpan,n)),:)
    !sx(0,jpan+2,n,:)      = s(inn(ind(1,jpan,n)),:)
    !sx(ipan+2,jpan+1,n,:) = s(iee(ind(ipan,jpan,n)),:)
    !sx(ipan+1,jpan+2,n,:) = s(inn(ind(ipan,jpan,n)),:)
    !sx(0,jpan+1,n,:)      = 0.5*(s(iw(ind(1,jpan,n)),:)+s(in(ind(1,jpan,n)),:))
    !sx(ipan+1,jpan+1,n,:) = 0.5*(s(ie(ind(ipan,jpan,n)),:)+s(in(ind(ipan,jpan,n)),:))
  end do               ! n loop

  do iq=1,ifull
    if (wtr(iq)) then
      do k=1,kx
!       Convert face index from 0:npanels to array indices
        idel=int(xg(iq,k))
        xxg=xg(iq,k)-idel
        jdel=int(yg(iq,k))
        yyg=yg(iq,k)-jdel
        ! Now make them proper indices in this processor's region
        idel = idel - ioff(nface(iq,k))
        jdel = jdel - joff(nface(iq,k))
        n = nface(iq,k) + noff ! Make this a local index
        if ( idel < 0 .or. idel > ipan .or. jdel < 0 .or. &
             jdel > jpan .or. n < 1 .or. n > npan ) then
          cycle      ! Will be calculated on another processor
        end if

        sc(0,-1) = sx(idel  ,jdel-1,n,k)
        sc(1,-1) = sx(idel+1,jdel-1,n,k)

        sc(-1,0) = sx(idel-1,jdel,n,k)
        sc(0,0)  = sx(idel  ,jdel,n,k)
        sc(1,0)  = sx(idel+1,jdel,n,k)
        sc(2,0)  = sx(idel+2,jdel,n,k)

        sc(-1,1) = sx(idel-1,jdel+1,n,k)
        sc(0,1)  = sx(idel  ,jdel+1,n,k)
        sc(1,1)  = sx(idel+1,jdel+1,n,k)
        sc(2,1)  = sx(idel+2,jdel+1,n,k)

        sc(0,2) = sx(idel  ,jdel+2,n,k)
        sc(1,2) = sx(idel+1,jdel+2,n,k)

        ncount=count(sc.gt.cxx+1.)
        if (ncount.ge.12) then
          r(2) = ((1.-xxg)*((2.-xxg)*((1.+xxg)*sc(0,0)-xxg*sc(-1,0)/3.) &
               -xxg*(1.+xxg)*sc(2,0)/3.)+xxg*(1.+xxg)*(2.-xxg)*sc(1,0))/2.
          r(3) = ((1.-xxg)*((2.-xxg)*((1.+xxg)*sc(0,1)-xxg*sc(-1,1)/3.) &
               -xxg*(1.+xxg)*sc(2,1)/3.)+xxg*(1.+xxg)*(2.-xxg)*sc(1,1))/2.
          r(1) = (1.-xxg)*sc(0,-1)+xxg*sc(1,-1)
          r(4) = (1.-xxg)*sc(0,2) +xxg*sc(1,2)

          s(iq,k) = ((1.-yyg)*((2.-yyg)* &
               ((1.+yyg)*r(2)-yyg*r(1)/3.)           &
               -yyg*(1.+yyg)*r(4)/3.)                &
               +yyg*(1.+yyg)*(2.-yyg)*r(3))/2.
        else
          where (sc(0:1,0:1).lt.cxx+1.)
            sc(0:1,0:1)=0.
          end where
          aad=sc(1,1)-sc(0,1)-sc(1,0)+sc(0,0)
          aab=sc(1,0)-sc(0,0)
          aac=sc(0,1)-sc(0,0)
          s(iq,k)=aab*xxg+aac*yyg+aad*xxg*yyg+sc(0,0)
        end if
      end do ! k loop
    end if   ! wtr
  end do      ! iq loop

! Loop over points that need to be calculated for other processes

  call intssend(s)

  do iproc=0,nproc-1
    if ( iproc == myid ) then
      cycle
    end if
    do iq=1,drlen(iproc)
      !  Convert face index from 0:npanels to array indices
      ip = min(il_g,max(1,nint(dpoints(iproc)%a(2,iq))))
      jp = min(il_g,max(1,nint(dpoints(iproc)%a(3,iq))))
      n = nint(dpoints(iproc)%a(1,iq)) + noff ! Local index
      !  Need global face index in fproc call
      idel = int(dpoints(iproc)%a(2,iq))
      xxg = dpoints(iproc)%a(2,iq) - idel
      jdel = int(dpoints(iproc)%a(3,iq))
      yyg = dpoints(iproc)%a(3,iq) - jdel
      k = nint(dpoints(iproc)%a(4,iq))
      idel = idel - ioff(n-noff)
      jdel = jdel - joff(n-noff)

      sc(-1,0) = sx(idel-1,jdel,n,k)
      sc(0,0)  = sx(idel  ,jdel,n,k)
      sc(1,0)  = sx(idel+1,jdel,n,k)
      sc(2,0)  = sx(idel+2,jdel,n,k)

      sc(-1,1) = sx(idel-1,jdel+1,n,k)
      sc(0,1)  = sx(idel  ,jdel+1,n,k)
      sc(1,1)  = sx(idel+1,jdel+1,n,k)
      sc(2,1)  = sx(idel+2,jdel+1,n,k)

      sc(0,-1) = sx(idel  ,jdel-1,n,k)
      sc(1,-1) = sx(idel+1,jdel-1,n,k)

      sc(0,2) = sx(idel  ,jdel+2,n,k)
      sc(1,2) = sx(idel+1,jdel+2,n,k)

      ncount=count(sc.gt.cxx+1.)
      if (ncount.ge.12) then
        r(2) = ((1.-xxg)*((2.-xxg)*((1.+xxg)*sc(0,0)-xxg*sc(-1,0)/3.) &
             -xxg*(1.+xxg)*sc(2,0)/3.)+xxg*(1.+xxg)*(2.-xxg)*sc(1,0))/2.
        r(3) = ((1.-xxg)*((2.-xxg)*((1.+xxg)*sc(0,1)-xxg*sc(-1,1)/3.) &
             -xxg*(1.+xxg)*sc(2,1)/3.)+xxg*(1.+xxg)*(2.-xxg)*sc(1,1))/2.
        r(1) = (1.-xxg)*sc(0,-1) +xxg*sc(1,-1)
        r(4) = (1.-xxg)*sc(0,2) +xxg*sc(1,2)

        sextra(iproc)%a(iq) = ((1.-yyg)*((2.-yyg)* &
             ((1.+yyg)*r(2)-yyg*r(1)/3.)           &
             -yyg*(1.+yyg)*r(4)/3.)                &
             +yyg*(1.+yyg)*(2.-yyg)*r(3))/2.
      else
        where (sc(0:1,0:1).lt.cxx+1.)
          sc(0:1,0:1)=0.
        end where       
        aad=sc(1,1)-sc(0,1)-sc(1,0)+sc(0,0)
        aab=sc(1,0)-sc(0,0)
        aac=sc(0,1)-sc(0,0)
        sextra(iproc)%a(iq)=aab*xxg+aac*yyg+aad*xxg*yyg+sc(0,0)
      end if
    end do            ! iq loop
  end do              ! iproc loop
            
!========================   end of intsch=1 section ====================
else     ! if(intsch==1)then
!======================== start of intsch=2 section ====================
!       this is intsc           NS interps done first
!       first extend s arrays into sx - this one -1:il+2 & -1:il+2

  do n=1,npan         ! first simple copy into larger array
    do j=1,jpan
      do i=1,ipan
        sx(i,j,n,:) = s(ind(i,j,n),:)
      end do         ! i loop
      sx(0,j,n,:)      = s(iw(ind(1,j,n)),:)
      sx(-1,j,n,:)     = s(iww(ind(1,j,n)),:)
      sx(ipan+1,j,n,:) = s(ie(ind(ipan,j,n)),:)
      sx(ipan+2,j,n,:) = s(iee(ind(ipan,j,n)),:)
    end do            ! j loop
    do i=1,ipan
      sx(i,0,n,:)      = s(is(ind(i,1,n)),:)
      sx(i,-1,n,:)     = s(iss(ind(i,1,n)),:)
      sx(i,jpan+1,n,:) = s(in(ind(i,jpan,n)),:)
      sx(i,jpan+2,n,:) = s(inn(ind(i,jpan,n)),:)
    end do            ! i loop
!        for ns interpolation, sometimes need (different from ew):
!            (-1,0),   (0,0),   (0,-1)   (-1,il+1),   (0,il+1),   (0,il+2)
!          (il+1,0),(il+2,0),(il+1,-1) (il+1,il+1),(il+2,il+1),(il+1,il+2)

    sx(-1,0,n,:)          = s(lsww(n),:)
    sx(0,0,n,:)           = s(isw(ind(1,1,n)),:)
    sx(0,-1,n,:)          = s(lssw(n),:)
    sx(ipan+2,0,n,:)      = s(lsee(n),:)
    sx(ipan+1,-1,n,:)     = s(lsse(n),:)
    sx(-1,jpan+1,n,:)     = s(lnww(n),:)
    sx(0,jpan+1,n,:)      = s(inw(ind(1,jpan,n)),:)
    sx(0,jpan+2,n,:)      = s(lnnw(n),:)
    sx(ipan+2,jpan+1,n,:) = s(lnee(n),:)
    sx(ipan+1,jpan+2,n,:) = s(lnne(n),:)
    sx(ipan+1,0,n,:)      = s(ise(ind(ipan,1,n)),:)
    sx(ipan+1,jpan+1,n,:) = s(ine(ind(ipan,jpan,n)),:)
  end do               ! n loop

  do iq=1,ifull
    if (wtr(iq)) then
      do k=1,kx
!       Convert face index from 0:npanels to array indices
        idel=int(xg(iq,k))
        xxg=xg(iq,k)-idel
        jdel=int(yg(iq,k))
        yyg=yg(iq,k)-jdel
        ! Now make them proper indices in this processor's region
        idel = idel - ioff(nface(iq,k))
        jdel = jdel - joff(nface(iq,k))
        n = nface(iq,k) + noff ! Make this a local index
        if ( idel < 0 .or. idel > ipan .or. jdel < 0 .or. &
             jdel > jpan .or. n < 1 .or. n > npan ) then
          cycle      ! Will be calculated on another processor
        end if

        sc(0,-1) = sx(idel,jdel-1,n,k)
        sc(0,0)  = sx(idel,jdel  ,n,k)
        sc(0,1)  = sx(idel,jdel+1,n,k)
        sc(0,2)  = sx(idel,jdel+2,n,k)

        sc(1,-1) = sx(idel+1,jdel-1,n,k)
        sc(1,0)  = sx(idel+1,jdel  ,n,k)
        sc(1,1)  = sx(idel+1,jdel+1,n,k)
        sc(1,2)  = sx(idel+1,jdel+2,n,k)

        sc(-1,0) = sx(idel-1,jdel  ,n,k)
        sc(-1,1) = sx(idel-1,jdel+1,n,k)
        
        sc(2,0) = sx(idel+2,jdel  ,n,k)
        sc(2,1) = sx(idel+2,jdel+1,n,k)
        
        ncount=count(sc.gt.cxx+1.)
        if (ncount.ge.12) then
          r(2) = ((1.-yyg)*((2.-yyg)*((1.+yyg)*sc(0,0)-yyg*sc(0,-1)/3.) &
               -yyg*(1.+yyg)*sc(0,2)/3.)+yyg*(1.+yyg)*(2.-yyg)*sc(0,1))/2.
          r(3) = ((1.-yyg)*((2.-yyg)*((1.+yyg)*sc(1,0)-yyg*sc(1,-1)/3.) &
               -yyg*(1.+yyg)*sc(1,2)/3.)+yyg*(1.+yyg)*(2.-yyg)*sc(1,1))/2.
          r(1) = (1.-yyg)*sc(-1,0)+yyg*sc(-1,1)
          r(4) = (1.-yyg)*sc(2,0) +yyg*sc(2,1)

          s(iq,k) = ((1.-xxg)*((2.-xxg)*       &
               ((1.+xxg)*r(2)-xxg*r(1)/3.)     &
               -xxg*(1.+xxg)*r(4)/3.)          &
               +xxg*(1.+xxg)*(2.-xxg)*r(3))/2.
        else
          where (sc(0:1,0:1).lt.cxx+1.)
            sc(0:1,0:1)=0.
          end where      
          aad=sc(1,1)-sc(0,1)-sc(1,0)+sc(0,0)
          aab=sc(1,0)-sc(0,0)
          aac=sc(0,1)-sc(0,0)
          s(iq,k)=aab*xxg+aac*yyg+aad*xxg*yyg+sc(0,0)
        end if
      end do
    end if
  end do

! For other processes
  call intssend(s)

  do iproc=0,nproc-1
    if ( iproc == myid ) then
      cycle
    end if
    do iq=1,drlen(iproc)
      !  Convert face index from 0:npanels to array indices
      ip = min(il_g,max(1,nint(dpoints(iproc)%a(2,iq))))
      jp = min(il_g,max(1,nint(dpoints(iproc)%a(3,iq))))
      n = nint(dpoints(iproc)%a(1,iq)) + noff ! Local index
      !  Need global face index in fproc call
      idel = int(dpoints(iproc)%a(2,iq))
      xxg = dpoints(iproc)%a(2,iq) - idel
      jdel = int(dpoints(iproc)%a(3,iq))
      yyg = dpoints(iproc)%a(3,iq) - jdel
      k = nint(dpoints(iproc)%a(4,iq))
      idel = idel - ioff(n-noff)
      jdel = jdel - joff(n-noff)

      sc(0,-1) = sx(idel,jdel-1,n,k)
      sc(0,0)  = sx(idel,jdel  ,n,k)
      sc(0,1)  = sx(idel,jdel+1,n,k)
      sc(0,2)  = sx(idel,jdel+2,n,k)

      sc(1,-1) = sx(idel+1,jdel-1,n,k)
      sc(1,0)  = sx(idel+1,jdel  ,n,k)
      sc(1,1)  = sx(idel+1,jdel+1,n,k)
      sc(1,2)  = sx(idel+1,jdel+2,n,k)

      sc(-1,0) = sx(idel-1,jdel  ,n,k)
      sc(-1,1) = sx(idel-1,jdel+1,n,k)
        
      sc(2,0) = sx(idel+2,jdel  ,n,k)
      sc(2,1) = sx(idel+2,jdel+1,n,k)

      ncount=count(sc.gt.cxx+1.)
      if (ncount.ge.12) then
        r(2) = ((1.-yyg)*((2.-yyg)*((1.+yyg)*sc(0,0)-yyg*sc(0,-1)/3.) &
             -yyg*(1.+yyg)*sc(0,2)/3.)+yyg*(1.+yyg)*(2.-yyg)*sc(0,1))/2.
        r(3) = ((1.-yyg)*((2.-yyg)*((1.+yyg)*sc(1,0)-yyg*sc(1,-1)/3.) &
             -yyg*(1.+yyg)*sc(1,2)/3.)+yyg*(1.+yyg)*(2.-yyg)*sc(1,1))/2.
        r(1) = (1.-yyg)*sc(-1,0) +yyg*sc(-1,1)
        r(4) = (1.-yyg)*sc(2,0) +yyg*sc(2,1)
        sextra(iproc)%a(iq) = ((1.-xxg)*((2.-xxg)* &
             ((1.+xxg)*r(2)-xxg*r(1)/3.)           &
             -xxg*(1.+xxg)*r(4)/3.)                &
             +xxg*(1.+xxg)*(2.-xxg)*r(3))/2.
      else
        where (sc(0:1,0:1).lt.cxx+1.)
          sc(0:1,0:1)=0.
        end where       
        aad=sc(1,1)-sc(0,1)-sc(1,0)+sc(0,0)
        aab=sc(1,0)-sc(0,0)
        aac=sc(0,1)-sc(0,0)
        sextra(iproc)%a(iq)=aab*xxg+aac*yyg+aad*xxg*yyg+sc(0,0)
      end if
    end do            ! iq loop
  end do              ! iproc

endif                     ! (intsch==1) .. else ..
!========================   end of intsch=1 section ====================

call intssync(s)

do iq=1,ifull
  if (.not.wtr(iq)) then
    s(iq,:)=0.
  end if
end do

return
end subroutine mlob2ints

! This version is for scalars which is same as above, but
! missing land values are filled from non-trivial values
! instead of being set to zero
subroutine mlob2intsb(s,nface,xg,yg,wtr)

use cc_mpi
use indices_m
use mlo

implicit none

include 'newmpar.h'
include 'parm.h'
include 'parmhor.h'
include 'mpif.h'

integer idel,iq,jdel,kx
integer i,j,k,n,ind,ip,jp,iproc,ierr,intsch,ncount
integer, dimension(:,:), intent(in) :: nface
real, dimension(ifull,size(nface,2)), intent(in) :: xg,yg
real, dimension(ifull+iextra,size(nface,2)), intent(inout) :: s
real, dimension(ifull,size(nface,2)) :: ssav
real, dimension(-1:ipan+2,-1:jpan+2,1:npan,size(nface,2)) :: sx
real, dimension(-1:2,-1:2) :: sc
real, dimension(0:1,0:1) :: scb
real, dimension(4) :: r
real xxg,yyg,aab,aac,aad
real cmax,cmin,cxx
logical, dimension(ifull+iextra), intent(in) :: wtr
ind(i,j,n)=i+(j-1)*ipan+(n-1)*ipan*jpan  ! *** for n=1,npan

kx=size(nface,2)
intsch=mod(ktau,2)
cxx=-999.
sx=cxx
sc=cxx
do k=1,kx
  do iq=1,ifull
    ssav(iq,k)=s(iq,k)
  end do
end do

do iq=1,ifull
  if (.not.wtr(iq)) then
    s(iq,:)=cxx
  end if
end do
call bounds(s,nrows=2)

!======================== start of intsch=1 section ====================
if(intsch==1)then

  do n=1,npan         ! first simple copy into larger array
    do j=1,jpan
      do i=1,ipan
        sx(i,j,n,:) = s(ind(i,j,n),:)
      end do         ! i loop
      sx(0,j,n,:)      = s(iw(ind(1,j,n)),:)
      sx(-1,j,n,:)     = s(iww(ind(1,j,n)),:)
      sx(ipan+1,j,n,:) = s(ie(ind(ipan,j,n)),:)
      sx(ipan+2,j,n,:) = s(iee(ind(ipan,j,n)),:)
    end do            ! j loop
    do i=1,ipan
      sx(i,0,n,:)      = s(is(ind(i,1,n)),:)
      sx(i,-1,n,:)     = s(iss(ind(i,1,n)),:)
      sx(i,jpan+1,n,:) = s(in(ind(i,jpan,n)),:)
      sx(i,jpan+2,n,:) = s(inn(ind(i,jpan,n)),:)
    end do            ! i loop
!   for ew interpolation, sometimes need (different from ns):
!       (-1,0),   (0,0),   (0,-1)   (-1,il+1),   (0,il+1),   (0,il+2)
!     (il+1,0),(il+2,0),(il+1,-1) (il+1,il+1),(il+2,il+1),(il+1,il+2)

    sx(-1,0,n,:)          = s(lwws(n),:)
    sx(0,0,n,:)           = s(iws(ind(1,1,n)),:)
    sx(0,-1,n,:)          = s(lwss(n),:)
    sx(ipan+1,0,n,:)      = s(ies(ind(ipan,1,n)),:)
    sx(ipan+2,0,n,:)      = s(lees(n),:)
    sx(ipan+1,-1,n,:)     = s(less(n),:)
    sx(-1,jpan+1,n,:)     = s(lwwn(n),:)
    sx(0,jpan+2,n,:)      = s(lwnn(n),:)
    sx(ipan+2,jpan+1,n,:) = s(leen(n),:)
    sx(ipan+1,jpan+2,n,:) = s(lenn(n),:)
    sx(0,jpan+1,n,:)      = s(iwn(ind(1,jpan,n)),:)
    sx(ipan+1,jpan+1,n,:) = s(ien(ind(ipan,jpan,n)),:)
  end do               ! n loop

  do iq=1,ifull
    if (wtr(iq)) then
      do k=1,kx
!       Convert face index from 0:npanels to array indices
        idel=int(xg(iq,k))
        xxg=xg(iq,k)-idel
        jdel=int(yg(iq,k))
        yyg=yg(iq,k)-jdel
        ! Now make them proper indices in this processor's region
        idel = idel - ioff(nface(iq,k))
        jdel = jdel - joff(nface(iq,k))
        n = nface(iq,k) + noff ! Make this a local index
        if ( idel < 0 .or. idel > ipan .or. jdel < 0 .or. &
             jdel > jpan .or. n < 1 .or. n > npan ) then
          cycle      ! Will be calculated on another processor
        end if

        sc(0,-1) = sx(idel  ,jdel-1,n,k)
        sc(1,-1) = sx(idel+1,jdel-1,n,k)

        sc(-1,0) = sx(idel-1,jdel,n,k)
        sc(0,0)  = sx(idel  ,jdel,n,k)
        sc(1,0)  = sx(idel+1,jdel,n,k)
        sc(2,0)  = sx(idel+2,jdel,n,k)

        sc(-1,1) = sx(idel-1,jdel+1,n,k)
        sc(0,1)  = sx(idel  ,jdel+1,n,k)
        sc(1,1)  = sx(idel+1,jdel+1,n,k)
        sc(2,1)  = sx(idel+2,jdel+1,n,k)

        sc(0,2) = sx(idel  ,jdel+2,n,k)
        sc(1,2) = sx(idel+1,jdel+2,n,k)

        ncount=count(sc.gt.cxx+1.)
        if (ncount.ge.12) then
          r(2) = ((1.-xxg)*((2.-xxg)*((1.+xxg)*sc(0,0)-xxg*sc(-1,0)/3.) &
               -xxg*(1.+xxg)*sc(2,0)/3.)+xxg*(1.+xxg)*(2.-xxg)*sc(1,0))/2.
          r(3) = ((1.-xxg)*((2.-xxg)*((1.+xxg)*sc(0,1)-xxg*sc(-1,1)/3.) &
               -xxg*(1.+xxg)*sc(2,1)/3.)+xxg*(1.+xxg)*(2.-xxg)*sc(1,1))/2.
          r(1) = (1.-xxg)*sc(0,-1)+xxg*sc(1,-1)
          r(4) = (1.-xxg)*sc(0,2) +xxg*sc(1,2)

          s(iq,k) = ((1.-yyg)*((2.-yyg)* &
               ((1.+yyg)*r(2)-yyg*r(1)/3.)           &
               -yyg*(1.+yyg)*r(4)/3.)                &
               +yyg*(1.+yyg)*(2.-yyg)*r(3))/2.
        else
          scb=sc(0:1,0:1)
          call lfill(scb,s(iq,k))
          sc(0:1,0:1)=scb        
          aad=sc(1,1)-sc(0,1)-sc(1,0)+sc(0,0)
          aab=sc(1,0)-sc(0,0)
          aac=sc(0,1)-sc(0,0)
          s(iq,k)=aab*xxg+aac*yyg+aad*xxg*yyg+sc(0,0)
        end if
        cmax=maxval(sc(0:1,0:1))
        cmin=minval(sc(0:1,0:1))
        s(iq,k)=min(max(s(iq,k),cmin),cmax)
      end do ! k loop
    end if   ! wtr
  end do     ! iq loop

! Loop over points that need to be calculated for other processes

  call intssend(s)

  do iproc=0,nproc-1
    if ( iproc == myid ) then
      cycle
    end if
    do iq=1,drlen(iproc)
      !  Convert face index from 0:npanels to array indices
      ip = min(il_g,max(1,nint(dpoints(iproc)%a(2,iq))))
      jp = min(il_g,max(1,nint(dpoints(iproc)%a(3,iq))))
      n = nint(dpoints(iproc)%a(1,iq)) + noff ! Local index
      !  Need global face index in fproc call
      idel = int(dpoints(iproc)%a(2,iq))
      xxg = dpoints(iproc)%a(2,iq) - idel
      jdel = int(dpoints(iproc)%a(3,iq))
      yyg = dpoints(iproc)%a(3,iq) - jdel
      k = nint(dpoints(iproc)%a(4,iq))
      idel = idel - ioff(n-noff)
      jdel = jdel - joff(n-noff)

      sc(-1,0) = sx(idel-1,jdel,n,k)
      sc(0,0)  = sx(idel  ,jdel,n,k)
      sc(1,0)  = sx(idel+1,jdel,n,k)
      sc(2,0)  = sx(idel+2,jdel,n,k)

      sc(-1,1) = sx(idel-1,jdel+1,n,k)
      sc(0,1)  = sx(idel  ,jdel+1,n,k)
      sc(1,1)  = sx(idel+1,jdel+1,n,k)
      sc(2,1)  = sx(idel+2,jdel+1,n,k)

      sc(0,-1) = sx(idel  ,jdel-1,n,k)
      sc(1,-1) = sx(idel+1,jdel-1,n,k)

      sc(0,2) = sx(idel  ,jdel+2,n,k)
      sc(1,2) = sx(idel+1,jdel+2,n,k)

      ncount=count(sc.gt.cxx+1.)
      if (ncount.ge.12) then
        r(2) = ((1.-xxg)*((2.-xxg)*((1.+xxg)*sc(0,0)-xxg*sc(-1,0)/3.) &
             -xxg*(1.+xxg)*sc(2,0)/3.)+xxg*(1.+xxg)*(2.-xxg)*sc(1,0))/2.
        r(3) = ((1.-xxg)*((2.-xxg)*((1.+xxg)*sc(0,1)-xxg*sc(-1,1)/3.) &
             -xxg*(1.+xxg)*sc(2,1)/3.)+xxg*(1.+xxg)*(2.-xxg)*sc(1,1))/2.
        r(1) = (1.-xxg)*sc(0,-1) +xxg*sc(1,-1)
        r(4) = (1.-xxg)*sc(0,2) +xxg*sc(1,2)

        sextra(iproc)%a(iq) = ((1.-yyg)*((2.-yyg)* &
             ((1.+yyg)*r(2)-yyg*r(1)/3.)           &
             -yyg*(1.+yyg)*r(4)/3.)                &
             +yyg*(1.+yyg)*(2.-yyg)*r(3))/2.
      else
        scb=sc(0:1,0:1)
        call lfill(scb,sextra(iproc)%a(iq))
        sc(0:1,0:1)=scb        
        aad=sc(1,1)-sc(0,1)-sc(1,0)+sc(0,0)
        aab=sc(1,0)-sc(0,0)
        aac=sc(0,1)-sc(0,0)
        sextra(iproc)%a(iq)=aab*xxg+aac*yyg+aad*xxg*yyg+sc(0,0)
      end if
      cmax=maxval(sc(0:1,0:1))
      cmin=minval(sc(0:1,0:1))
      sextra(iproc)%a(iq)=min(max(sextra(iproc)%a(iq),cmin),cmax)
    end do            ! iq loop
  end do              ! iproc loop
       
!========================   end of intsch=1 section ====================
else     ! if(intsch==1)then
!======================== start of intsch=2 section ====================
!       this is intsc           NS interps done first
!       first extend s arrays into sx - this one -1:il+2 & -1:il+2

  do n=1,npan         ! first simple copy into larger array
    do j=1,jpan
      do i=1,ipan
        sx(i,j,n,:) = s(ind(i,j,n),:)
      end do         ! i loop
      sx(0,j,n,:)      = s(iw(ind(1,j,n)),:)
      sx(-1,j,n,:)     = s(iww(ind(1,j,n)),:)
      sx(ipan+1,j,n,:) = s(ie(ind(ipan,j,n)),:)
      sx(ipan+2,j,n,:) = s(iee(ind(ipan,j,n)),:)
    end do            ! j loop
    do i=1,ipan
      sx(i,0,n,:)      = s(is(ind(i,1,n)),:)
      sx(i,-1,n,:)     = s(iss(ind(i,1,n)),:)
      sx(i,jpan+1,n,:) = s(in(ind(i,jpan,n)),:)
      sx(i,jpan+2,n,:) = s(inn(ind(i,jpan,n)),:)
    end do            ! i loop
!        for ns interpolation, sometimes need (different from ew):
!            (-1,0),   (0,0),   (0,-1)   (-1,il+1),   (0,il+1),   (0,il+2)
!          (il+1,0),(il+2,0),(il+1,-1) (il+1,il+1),(il+2,il+1),(il+1,il+2)

    sx(-1,0,n,:)          = s(lsww(n),:)
    sx(0,0,n,:)           = s(isw(ind(1,1,n)),:)
    sx(0,-1,n,:)          = s(lssw(n),:)
    sx(ipan+2,0,n,:)      = s(lsee(n),:)
    sx(ipan+1,-1,n,:)     = s(lsse(n),:)
    sx(-1,jpan+1,n,:)     = s(lnww(n),:)
    sx(0,jpan+1,n,:)      = s(inw(ind(1,jpan,n)),:)
    sx(0,jpan+2,n,:)      = s(lnnw(n),:)
    sx(ipan+2,jpan+1,n,:) = s(lnee(n),:)
    sx(ipan+1,jpan+2,n,:) = s(lnne(n),:)
    sx(ipan+1,0,n,:)      = s(ise(ind(ipan,1,n)),:)
    sx(ipan+1,jpan+1,n,:) = s(ine(ind(ipan,jpan,n)),:)
  end do               ! n loop

  do iq=1,ifull
    if (wtr(iq)) then
      do k=1,kx
!       Convert face index from 0:npanels to array indices
        idel=int(xg(iq,k))
        xxg=xg(iq,k)-idel
        jdel=int(yg(iq,k))
        yyg=yg(iq,k)-jdel
        ! Now make them proper indices in this processor's region
        idel = idel - ioff(nface(iq,k))
        jdel = jdel - joff(nface(iq,k))
        n = nface(iq,k) + noff ! Make this a local index
        if ( idel < 0 .or. idel > ipan .or. jdel < 0 .or. &
             jdel > jpan .or. n < 1 .or. n > npan ) then
          cycle      ! Will be calculated on another processor
        end if

        sc(0,-1) = sx(idel,jdel-1,n,k)
        sc(0,0)  = sx(idel,jdel  ,n,k)
        sc(0,1)  = sx(idel,jdel+1,n,k)
        sc(0,2)  = sx(idel,jdel+2,n,k)

        sc(1,-1) = sx(idel+1,jdel-1,n,k)
        sc(1,0)  = sx(idel+1,jdel  ,n,k)
        sc(1,1)  = sx(idel+1,jdel+1,n,k)
        sc(1,2)  = sx(idel+1,jdel+2,n,k)

        sc(-1,0) = sx(idel-1,jdel  ,n,k)
        sc(-1,1) = sx(idel-1,jdel+1,n,k)
        
        sc(2,0) = sx(idel+2,jdel  ,n,k)
        sc(2,1) = sx(idel+2,jdel+1,n,k)
        
        ncount=count(sc.gt.cxx+1.)
        if (ncount.ge.12) then
          r(2) = ((1.-yyg)*((2.-yyg)*((1.+yyg)*sc(0,0)-yyg*sc(0,-1)/3.) &
               -yyg*(1.+yyg)*sc(0,2)/3.)+yyg*(1.+yyg)*(2.-yyg)*sc(0,1))/2.
          r(3) = ((1.-yyg)*((2.-yyg)*((1.+yyg)*sc(1,0)-yyg*sc(1,-1)/3.) &
               -yyg*(1.+yyg)*sc(1,2)/3.)+yyg*(1.+yyg)*(2.-yyg)*sc(1,1))/2.
          r(1) = (1.-yyg)*sc(-1,0)+yyg*sc(-1,1)
          r(4) = (1.-yyg)*sc(2,0) +yyg*sc(2,1)

          s(iq,k) = ((1.-xxg)*((2.-xxg)*       &
               ((1.+xxg)*r(2)-xxg*r(1)/3.)     &
               -xxg*(1.+xxg)*r(4)/3.)          &
               +xxg*(1.+xxg)*(2.-xxg)*r(3))/2.
        else
          scb=sc(0:1,0:1)
          call lfill(scb,s(iq,k))
          sc(0:1,0:1)=scb        
          aad=sc(1,1)-sc(0,1)-sc(1,0)+sc(0,0)
          aab=sc(1,0)-sc(0,0)
          aac=sc(0,1)-sc(0,0)
          s(iq,k)=aab*xxg+aac*yyg+aad*xxg*yyg+sc(0,0)
        end if
        cmax=maxval(sc(0:1,0:1))
        cmin=minval(sc(0:1,0:1))
        s(iq,k)=min(max(s(iq,k),cmin),cmax)
      end do
    end if
  end do

! For other processes
  call intssend(s)

  do iproc=0,nproc-1
    if ( iproc == myid ) then
      cycle
    end if
    do iq=1,drlen(iproc)
      !  Convert face index from 0:npanels to array indices
      ip = min(il_g,max(1,nint(dpoints(iproc)%a(2,iq))))
      jp = min(il_g,max(1,nint(dpoints(iproc)%a(3,iq))))
      n = nint(dpoints(iproc)%a(1,iq)) + noff ! Local index
      !  Need global face index in fproc call
      idel = int(dpoints(iproc)%a(2,iq))
      xxg = dpoints(iproc)%a(2,iq) - idel
      jdel = int(dpoints(iproc)%a(3,iq))
      yyg = dpoints(iproc)%a(3,iq) - jdel
      k = nint(dpoints(iproc)%a(4,iq))
      idel = idel - ioff(n-noff)
      jdel = jdel - joff(n-noff)

      sc(0,-1) = sx(idel,jdel-1,n,k)
      sc(0,0)  = sx(idel,jdel  ,n,k)
      sc(0,1)  = sx(idel,jdel+1,n,k)
      sc(0,2)  = sx(idel,jdel+2,n,k)

      sc(1,-1) = sx(idel+1,jdel-1,n,k)
      sc(1,0)  = sx(idel+1,jdel  ,n,k)
      sc(1,1)  = sx(idel+1,jdel+1,n,k)
      sc(1,2)  = sx(idel+1,jdel+2,n,k)

      sc(-1,0) = sx(idel-1,jdel  ,n,k)
      sc(-1,1) = sx(idel-1,jdel+1,n,k)
        
      sc(2,0) = sx(idel+2,jdel  ,n,k)
      sc(2,1) = sx(idel+2,jdel+1,n,k)

      ncount=count(sc.gt.cxx+1.)
      if (ncount.ge.12) then
        r(2) = ((1.-yyg)*((2.-yyg)*((1.+yyg)*sc(0,0)-yyg*sc(0,-1)/3.) &
             -yyg*(1.+yyg)*sc(0,2)/3.)+yyg*(1.+yyg)*(2.-yyg)*sc(0,1))/2.
        r(3) = ((1.-yyg)*((2.-yyg)*((1.+yyg)*sc(1,0)-yyg*sc(1,-1)/3.) &
             -yyg*(1.+yyg)*sc(1,2)/3.)+yyg*(1.+yyg)*(2.-yyg)*sc(1,1))/2.
        r(1) = (1.-yyg)*sc(-1,0) +yyg*sc(-1,1)
        r(4) = (1.-yyg)*sc(2,0) +yyg*sc(2,1)
        sextra(iproc)%a(iq) = ((1.-xxg)*((2.-xxg)* &
             ((1.+xxg)*r(2)-xxg*r(1)/3.)           &
             -xxg*(1.+xxg)*r(4)/3.)                &
             +xxg*(1.+xxg)*(2.-xxg)*r(3))/2.
      else
        scb=sc(0:1,0:1)
        call lfill(scb,sextra(iproc)%a(iq))
        sc(0:1,0:1)=scb        
        aad=sc(1,1)-sc(0,1)-sc(1,0)+sc(0,0)
        aab=sc(1,0)-sc(0,0)
        aac=sc(0,1)-sc(0,0)
        sextra(iproc)%a(iq)=aab*xxg+aac*yyg+aad*xxg*yyg+sc(0,0)
      end if
      cmax=maxval(sc(0:1,0:1))
      cmin=minval(sc(0:1,0:1))
      sextra(iproc)%a(iq)=min(max(sextra(iproc)%a(iq),cmin),cmax)
    end do            ! iq loop
  end do              ! iproc

endif                     ! (intsch==1) .. else ..
!========================   end of intsch=1 section ====================

call intssync(s)

do iq=1,ifull
  if (.not.wtr(iq)) then
    s(iq,:)=ssav(iq,:)
  end if
end do

return
end subroutine mlob2intsb

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Rotate wind vector to arrival point

subroutine mlorot(cou,cov,cow,x3d,y3d,z3d)

use mlo
use xyzinfo_m

implicit none

include 'newmpar.h'

integer k,kx
real, dimension(:,:), intent(inout) :: cou,cov,cow
real, dimension(ifull) :: vec1x,vec1y,vec1z,denb
real, dimension(ifull) :: vec2x,vec2y,vec2z,vecdot
real, dimension(ifull) :: vec3x,vec3y,vec3z,vdot1,vdot2
real*8, dimension(ifull,size(cou,2)), intent(in) :: x3d,y3d,z3d

kx=size(cou,2)

do k=1,kx
!         cross product n1xn2 into vec1
  vec1x = y3d(:,k)*z - y*z3d(:,k)
  vec1y = z3d(:,k)*x - z*x3d(:,k)
  vec1z = x3d(:,k)*y - x*y3d(:,k)
  denb = vec1x**2 + vec1y**2 + vec1z**2
!         N.B. rotation formula is singular for small denb,
!         but the rotation is unnecessary in this case
  where (denb>1.e-4)
    vecdot = x3d(:,k)*x + y3d(:,k)*y + z3d(:,k)*z
    vec2x = x3d(:,k)*vecdot - x
    vec2y = y3d(:,k)*vecdot - y
    vec2z = z3d(:,k)*vecdot - z
    vec3x = x3d(:,k) - vecdot*x
    vec3y = y3d(:,k) - vecdot*y
    vec3z = z3d(:,k) - vecdot*z
    vdot1 = (vec1x*cou(:,k) + vec1y*cov(:,k) + vec1z*cow(:,k))/denb
    vdot2 = (vec2x*cou(:,k) + vec2y*cov(:,k) + vec2z*cow(:,k))/denb
    cou(:,k) = vdot1*vec1x + vdot2*vec3x
    cov(:,k) = vdot1*vec1y + vdot2*vec3y
    cow(:,k) = vdot1*vec1z + vdot2*vec3z
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

implicit none

include 'newmpar.h'

integer k,itn,kx,iq
real, dimension(:,:), intent(in) :: u
real, dimension(ifull,size(u,2)), intent(in) :: v
real, dimension(ifull,size(u,2)), intent(out) :: uout,vout
real, dimension(ifull+iextra,size(u,2)) :: uin,vin
real, dimension(ifull+iextra,size(u,2)) :: ua,va
real, dimension(ifull,size(u,2)) :: ug,vg,ud,vd
integer, parameter :: itnmax=3

kx=size(u,2)

do k=1,kx
  uin(1:ifull,k)=u(:,k)*ee(1:ifull)
  vin(1:ifull,k)=v(:,k)*ee(1:ifull)
end do
call boundsuv(uin,vin,nrows=2)

do k=1,kx
  ud(1:ifull,k)=uin(iwu,k)*0.1+uin(1:ifull,k)+uin(ieu,k)*0.5
  vd(1:ifull,k)=vin(isv,k)*0.1+vin(1:ifull,k)+vin(inv,k)*0.5
end do
!call boundsuv(ud,vd)

do k=1,kx
  !ug(:,k)=ud(1:ifull,k)-0.5*ud(iwu,k)
  ug(:,k)=-0.05*uin(iwwu,k)-0.4*uin(iwu,k)+0.75*uin(1:ifull,k)+0.5*uin(ieu,k)
  !vg(:,k)=vd(1:ifull,k)-0.5*vd(isv,k)
  vg(:,k)=-0.05*vin(issv,k)-0.4*vin(isv,k)+0.75*vin(1:ifull,k)+0.5*vin(inv,k)
  ua(1:ifull,k)=ug(:,k)*eeu(1:ifull) ! 1st guess
  va(1:ifull,k)=vg(:,k)*eev(1:ifull) ! 1st guess
end do

do itn=1,itnmax        ! each loop is a double iteration
  call boundsuv(ua,va,nrows=2)
  do iq=1,ifull
    if (eeu(iwu(iq)).gt.0.5.and.eeu(iq).gt.0.5) then
      uin(iq,:)=(ug(iq,:)-ua(ieu(iq),:)*0.1+ua(iwwu(iq),:)*0.25)/0.95
    else if (eeu(iq).gt.0.5) then
      uin(iq,:)=ud(iq,:)-ua(ieu(iq),:)*0.1 !-ua(iwu(iq),:)*0.5
    else
      uin(iq,:)=0.
    end if
    if (eev(isv(iq)).gt.0.5.and.eev(iq).gt.0.5) then
      vin(iq,:)=(vg(iq,:)-va(inv(iq),:)*0.1+va(issv(iq),:)*0.25)/0.95
    else if (eev(iq).gt.0.5) then
      vin(iq,:)=vd(iq,:)-va(inv(iq),:)*0.1 !-va(isv(iq),:)*0.5
    else
      vin(iq,:)=0.
    end if
  end do
  call boundsuv(uin,vin,nrows=2)
  do iq=1,ifull
    if (eeu(iwu(iq)).gt.0.5.and.eeu(iq).gt.0.5) then
      ua(iq,:)=(ug(iq,:)-uin(ieu(iq),:)*0.1+uin(iwwu(iq),:)*0.25)/0.95
    else if (eeu(iq).gt.0.5) then
      ua(iq,:)=ud(iq,:)-uin(ieu(iq),:)*0.1 !-uin(iwu(iq),:)*0.5
    else
      ua(iq,:)=0.
    end if
    if (eev(isv(iq)).gt.0.5.and.eev(iq).gt.0.5) then
      va(iq,:)=(vg(iq,:)-vin(inv(iq),:)*0.1+vin(issv(iq),:)*0.25)/0.95
    else if (eev(iq).gt.0.5) then
      va(iq,:)=vd(iq,:)-vin(inv(iq),:)*0.1 !-vin(isv(iq),:)*0.5
    else
      va(iq,:)=0.
    end if
  end do
end do                 ! itn=1,itnmax

uout=ua(1:ifull,:)
vout=va(1:ifull,:)

return
end subroutine mlostaguv

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Unstagger u and v
! Modified to include zero velocity over land points
subroutine mlounstaguv(u,v,uout,vout)

use cc_mpi
use indices_m
use mlo

implicit none

include 'newmpar.h'

integer k,itn,kx,iq
real, dimension(:,:), intent(in) :: u
real, dimension(ifull,size(u,2)), intent(in) :: v
real, dimension(ifull,size(u,2)), intent(out) :: uout,vout
real, dimension(ifull+iextra,size(u,2)) :: uin,vin
real, dimension(ifull+iextra,size(u,2)) :: ua,va
real, dimension(ifull,size(u,2)) :: ug,vg,ud,vd
integer, parameter :: itnmax=3

kx=size(u,2)

do k=1,kx
  uin(1:ifull,k)=u(:,k)*eeu(1:ifull)
  vin(1:ifull,k)=v(:,k)*eev(1:ifull)
end do
call boundsuv(uin,vin,nrows=2)

do k=1,kx
  ud(1:ifull,k)=uin(ieu,k)*0.1+uin(1:ifull,k)+uin(iwu,k)*0.5
  vd(1:ifull,k)=vin(inv,k)*0.1+vin(1:ifull,k)+vin(isv,k)*0.5
end do
!call boundsuv(ud,vd)

do k=1,kx
  !ug(:,k)=ud(1:ifull,k)-0.5*ud(ieu,k)
  ug(:,k)=-0.05*uin(ieeu,k)-0.4*uin(ieu,k)+0.75*uin(1:ifull,k)+0.5*uin(iwu,k)
  !vg(:,k)=vd(1:ifull,k)-0.5*vd(inv,k)
  vg(:,k)=-0.05*vin(innv,k)-0.4*vin(inv,k)+0.75*vin(1:ifull,k)+0.5*vin(isv,k)
  ua(1:ifull,k)=ug(:,k)*ee(1:ifull) ! 1st guess
  va(1:ifull,k)=vg(:,k)*ee(1:ifull) ! 1st guess
end do

do itn=1,itnmax        ! each loop is a double iteration
  call boundsuv(ua,va,nrows=2)
  do iq=1,ifull
    if (ee(ie(iq)).gt.0.5.and.ee(iq).gt.0.5) then
      uin(iq,:)=(ug(iq,:)-ua(iwu(iq),:)*0.1+ua(ieeu(iq),:)*0.25)/0.95
    else if (ee(iq).gt.0.5) then
      uin(iq,:)=ud(iq,:)-ua(iwu(iq),:)*0.1 !-ua(ieu(iq),:)*0.5
    else
      uin(iq,:)=0.
    end if
    if (ee(in(iq)).gt.0.5.and.ee(iq).gt.0.5) then
      vin(iq,:)=(vg(iq,:)-va(isv(iq),:)*0.1+va(innv(iq),:)*0.25)/0.95
    else if (ee(iq).gt.0.5) then
      vin(iq,:)=vd(iq,:)-va(isv(iq),:)*0.1 !-va(inv(iq),:)*0.5
    else
      vin(iq,:)=0.
    end if
  end do
  call boundsuv(uin,vin,nrows=2)
  do iq=1,ifull
    if (ee(ie(iq)).gt.0.5.and.ee(iq).gt.0.5) then
      ua(iq,:)=(ug(iq,:)-uin(iwu(iq),:)*0.1+uin(ieeu(iq),:)*0.25)/0.95
    else if (ee(iq).gt.0.5) then
      ua(iq,:)=ud(iq,:)-uin(iwu(iq),:)*0.1 !-uin(ieu(iq),:)*0.5
    else
      ua(iq,:)=0.
    end if
    if (ee(in(iq)).gt.0.5.and.ee(iq).gt.0.5) then
      va(iq,:)=(vg(iq,:)-vin(isv(iq),:)*0.1+vin(innv(iq),:)*0.25)/0.95
    else if (ee(iq).gt.0.5) then
      va(iq,:)=vd(iq,:)-vin(isv(iq),:)*0.1 !-vin(inv(iq),:)*0.5
    else
      va(iq,:)=0.
    end if
  end do
enddo                  ! itn=1,itnmax
      
uout=ua(1:ifull,:)
vout=va(1:ifull,:)

return
end subroutine mlounstaguv

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! This subroutine performs vertical advection based on JLMs TVD scheme

subroutine mlovadv(dtin,ww,uu,vv,ss,tt,mm,depdum,dzdum,wtr,cnum)

use cc_mpi
use mlo

implicit none

include 'mpif.h'
include 'newmpar.h'

integer, intent(in) :: cnum
integer its,its_g,ii,l,iq,ierr
real, intent(in) :: dtin
real dtnew
real, dimension(ifull,0:wlev), intent(in) :: ww
real, dimension(ifull,wlev), intent(in) :: depdum,dzdum
real, dimension(ifull,wlev), intent(inout) :: uu,vv,ss,tt,mm
logical, dimension(ifull), intent(in) :: wtr

! reduce time step to ensure stability
dtnew=dtin
do iq=1,ifull
  if (wtr(iq)) then
    do ii=1,wlev-1
      dtnew=min(dtnew,0.3*dzdum(iq,ii)/max(abs(ww(iq,ii)),1.E-12))
    end do
  end if
end do
its=int(dtin/dtnew)+1
call MPI_AllReduce(its,its_g,1,MPI_INTEGER,MPI_MAX,MPI_COMM_WORLD,ierr)
dtnew=dtin/real(its_g)

if (its_g.gt.500.and.myid.eq.0) write(6,*) "MLOVERT cnum,its_g",cnum,its_g

tt=tt-290.
ss=ss-34.72
do l=1,its_g
  call mlotvd(dtnew,ww,uu,depdum,dzdum)
  call mlotvd(dtnew,ww,vv,depdum,dzdum)
  call mlotvd(dtnew,ww,ss,depdum,dzdum)
  call mlotvd(dtnew,ww,tt,depdum,dzdum)
  call mlotvd(dtnew,ww,mm,depdum,dzdum)
end do
tt=tt+290.
ss=ss+34.72
where (ss.lt.0.1)
  ss=0.
end where

return
end subroutine mlovadv

subroutine mlotvd(dtnew,ww,uu,depadj,dzadj)

use mlo

implicit none

include 'newmpar.h'

integer ii
real, intent(in) :: dtnew
real, dimension(ifull,0:wlev), intent(in) :: ww
real, dimension(ifull,wlev), intent(in) :: depadj,dzadj
real, dimension(ifull,wlev), intent(inout) :: uu
real, dimension(ifull,wlev-1) :: ff
real, dimension(ifull,0:wlev) :: delu
real, dimension(ifull) :: fl,fh,cc,rr,xx,jj

! f=(w*u) at half levels
! du/dt = u*dw/dz-df/dz = -w*du/dz

delu=0.
do ii=1,wlev-1
  delu(:,ii)=uu(:,ii+1)-uu(:,ii)
end do

! TVD part
do ii=1,wlev-1
  fl=0.5*ww(:,ii)*(uu(:,ii)+uu(:,ii+1))+0.5*abs(ww(:,ii))*(uu(:,ii)-uu(:,ii+1))
  fh=ww(:,ii)*0.5*(uu(:,ii)+uu(:,ii+1)) &
     -0.5*(uu(:,ii+1)-uu(:,ii))*ww(:,ii)**2*dtnew/max(depadj(:,ii+1)-depadj(:,ii),1.E-10)
  xx=delu(:,ii)+sign(1.E-20,delu(:,ii))
  jj=sign(1.,ww(:,ii))
  rr=0.5*((1.-jj)*delu(:,ii+1)+(1.+jj)*delu(:,ii-1))/xx
  cc=max(0.,min(1.,2.*rr),min(2.,rr)) ! superbee
  ff(:,ii)=fl+cc*(fh-fl)
  !ff(:,ii)=ww(:,ii)*0.5*(uu(:,ii)+uu(:,ii+1)) ! explicit
end do
uu(:,1)=uu(:,1)+dtnew*(uu(:,1)*ww(:,1)-ff(:,1))/dzadj(:,1)
do ii=2,wlev-1
  uu(:,ii)=uu(:,ii)+dtnew*(uu(:,ii)*(ww(:,ii)-ww(:,ii-1))-ff(:,ii)+ff(:,ii-1))/dzadj(:,ii)
end do
uu(:,wlev)=uu(:,wlev)+dtnew*(-uu(:,wlev)*ww(:,wlev-1)+ff(:,wlev-1))/dzadj(:,wlev)

return
end subroutine mlotvd

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Use potential temperature and salinity Jacobians to calculate
! density Jacobian

subroutine tsjacobi(nti,nsi,alphabar,betabar,neta,drhobardxu,drhobardyu,drhobardxv,drhobardyv)

use indices_m
use mlo, only : wlev

implicit none

include 'newmpar.h'

integer ii
real, dimension(ifull+iextra,wlev), intent(in) :: nti,nsi,alphabar,betabar
real, dimension(ifull+iextra), intent(in) :: neta
real, dimension(ifull,wlev), intent(out) :: drhobardxu,drhobardyu,drhobardxv,drhobardyv
real, dimension(ifull+iextra,wlev) :: nt,ns
real, dimension(ifull,wlev) :: absu,bbsu,absv,bbsv
real, dimension(ifull,wlev) :: dntdxu,dntdxv,dntdyu,dntdyv
real, dimension(ifull,wlev) :: dnsdxu,dnsdxv,dnsdyu,dnsdyv
integer, parameter :: rhogradmeth = 1 ! Density gradient method (0 = finite difference, 1 = local interpolation, 2 = pom stencil)

nt=min(max(273.1,nti),373.)
ns=min(max(0.,nsi),50.)

do ii=1,wlev
  absu(:,ii)=0.5*(alphabar(1:ifull,ii)+alphabar(ie,ii))
  bbsu(:,ii)=0.5*(betabar(1:ifull,ii)+betabar(ie,ii))
  absv(:,ii)=0.5*(alphabar(1:ifull,ii)+alphabar(in,ii))
  bbsv(:,ii)=0.5*(betabar(1:ifull,ii)+betabar(in,ii))
end do

select case(rhogradmeth)
  case(0) ! finite difference
    call finitedelta(nt,neta,dntdxu,dntdyu,dntdxv,dntdyv)
    call finitedelta(ns,neta,dnsdxu,dnsdyu,dnsdxv,dnsdyv)
  case(1) ! local interpolation
    call seekdelta(nt,neta,dntdxu,dntdyu,dntdxv,dntdyv)
    call seekdelta(ns,neta,dnsdxu,dnsdyu,dnsdxv,dnsdyv)
  case(2) ! POM stencil
    call pomdelta(nt,neta,dntdxu,dntdyu,dntdxv,dntdyv)
    call pomdelta(ns,neta,dnsdxu,dnsdyu,dnsdxv,dnsdyv)
  case default
    write(6,*) "ERROR: Invalid choice of rhogradmeth ",rhogradmeth
    stop
end select

drhobardxu=-absu*dntdxu+bbsu*dnsdxu
drhobardxv=-absv*dntdxv+bbsv*dnsdxv
drhobardyu=-absu*dntdyu+bbsu*dnsdyu
drhobardyv=-absv*dntdyv+bbsv*dnsdyv

return
end subroutine tsjacobi

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Calculate gradients using a finite difference method

subroutine finitedelta(rhobar,neta,drhobardxu,drhobardyu,drhobardxv,drhobardyv)

use indices_m
use map_m
use mlo, only : wlev,mindep

implicit none

include 'newmpar.h'
include 'parm.h'

integer ii
real, dimension(ifull+iextra,wlev), intent (in) :: rhobar
real, dimension(ifull+iextra), intent(in) :: neta
real, dimension(ifull,wlev), intent(out) :: drhobardxu,drhobardyu,drhobardxv,drhobardyv
real, dimension(ifull) :: drhobardzu,drhobardzv,tnu,tsu,tev,twv
real, dimension(ifull+iextra,0:wlev) :: rhobarhl,dephladj
real xp

! set-up level depths
dephladj(:,0)=0.
do ii=1,wlev
  dephladj(:,ii)=gosigh(ii)*max(dd(:)+neta(:),mindep)
end do

! estimate rhobar at half levels
rhobarhl(:,0)=rhobar(:,1)
do ii=1,wlev-1
  xp=gosigh(ii)-gosig(ii)
  rhobarhl(:,ii)=rhobar(:,ii)+xp*(rhobar(:,ii+1)-rhobar(:,ii))/(gosig(ii+1)-gosig(ii))
end do
rhobarhl(:,wlev)=rhobar(:,wlev)

do ii=1,wlev
  drhobardzu=(rhobarhl(1:ifull,ii)+rhobarhl(ie,ii)-rhobarhl(1:ifull,ii-1)-rhobarhl(ie,ii-1))          &
            /(dephladj(1:ifull,ii)+dephladj(ie,ii)-dephladj(1:ifull,ii-1)-dephladj(ie,ii-1))
  drhobardzv=(rhobarhl(1:ifull,ii)+rhobarhl(in,ii)-rhobarhl(1:ifull,ii-1)-rhobarhl(in,ii-1))          &
            /(dephladj(1:ifull,ii)+dephladj(in,ii)-dephladj(1:ifull,ii-1)-dephladj(in,ii-1))
  tnu=0.5*( rhobar(in,ii)+drhobardzu*((1.-gosig(ii))*neta(in) -gosig(ii)*dd(in) ) &
          +rhobar(ine,ii)+drhobardzu*((1.-gosig(ii))*neta(ine)-gosig(ii)*dd(ine)))
  tsu=0.5*( rhobar(is,ii)+drhobardzu*((1.-gosig(ii))*neta(is) -gosig(ii)*dd(is) ) &
          +rhobar(ise,ii)+drhobardzu*((1.-gosig(ii))*neta(ise)-gosig(ii)*dd(ise)))
  tev=0.5*( rhobar(ie,ii)+drhobardzv*((1.-gosig(ii))*neta(ie) -gosig(ii)*dd(ie) ) &
          +rhobar(ien,ii)+drhobardzv*((1.-gosig(ii))*neta(ien)-gosig(ii)*dd(ien)))
  twv=0.5*( rhobar(iw,ii)+drhobardzv*((1.-gosig(ii))*neta(iw) -gosig(ii)*dd(iw) ) &
          +rhobar(iwn,ii)+drhobardzv*((1.-gosig(ii))*neta(iwn)-gosig(ii)*dd(iwn)))
  drhobardxu(:,ii)=(rhobar(ie,ii)-rhobar(1:ifull,ii)+drhobardzu*((1.-gosig(ii))*(neta(ie)-neta(1:ifull)) &
                                                     -gosig(ii)*(dd(ie)-dd(1:ifull))))*emu(1:ifull)/ds
  drhobardxu(:,ii)=drhobardxu(:,ii)*eeu(1:ifull)                                                   
  drhobardyu(:,ii)=stwgt(1:ifull,1)*0.5*(tnu-tsu)*emu(1:ifull)/ds
  drhobardxv(:,ii)=stwgt(1:ifull,2)*0.5*(tev-twv)*emv(1:ifull)/ds
  drhobardyv(:,ii)=(rhobar(in,ii)-rhobar(1:ifull,ii)+drhobardzv*((1.-gosig(ii))*(neta(in)-neta(1:ifull)) &
                                                     -gosig(ii)*(dd(in)-dd(1:ifull))))*emv(1:ifull)/ds
  drhobardyv(:,ii)=drhobardyv(:,ii)*eev(1:ifull)
end do

return
end subroutine finitedelta

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Calculate gradients using an interpolation method

subroutine seekdelta(rhobar,neta,drhobardxu,drhobardyu,drhobardxv,drhobardyv)

use indices_m
use map_m
use mlo, only : wlev,mindep

implicit none

include 'newmpar.h'
include 'parm.h'

integer iqw,ii
integer sdi,sde,sdw,sdn,sds,sdne,sdse,sden,sdwn
real ddux,ddvy,ri,re,rw,rn,rs,rne,rse,ren,rwn
real mxi,mxe,mxw,mxn,mxs,mxne,mxse,mxen,mxwn
real drhobardzu,drhobardzv
real, dimension(wlev) :: ddi,dde,ddw,ddn,dds,ddne,ddse,dden,ddwn
real, dimension(wlev) :: ssi,sse,ssw,ssn,sss,ssne,ssse,ssen,sswn
real, dimension(ifull+iextra,wlev), intent (in) :: rhobar
real, dimension(ifull+iextra), intent(in) :: neta
real, dimension(ifull,wlev), intent(out) :: drhobardxu,drhobardyu,drhobardxv,drhobardyv
real, dimension(ifull+iextra,0:wlev) :: rhobarhl,dephladj
real xp

! set-up level depths
dephladj(:,0)=0.
do ii=1,wlev
  dephladj(:,ii)=gosigh(ii)*max(dd(:)+neta(:),mindep)
end do

! estimate rhobar at half levels
rhobarhl(:,0)=rhobar(:,1)
do ii=1,wlev-1
  xp=gosigh(ii)-gosig(ii)
  rhobarhl(:,ii)=rhobar(:,ii)+xp*(rhobar(:,ii+1)-rhobar(:,ii))/(gosig(ii+1)-gosig(ii))
end do
rhobarhl(:,wlev)=rhobar(:,wlev)

do iqw=1,ifull
  mxi=dd(iqw)
  mxe=dd(ie(iqw))
  mxn=dd(in(iqw))
  ssi=rhobar(iqw,:)
  sse=rhobar(ie(iqw),:)
  ssn=rhobar(in(iqw),:)
  ddi=gosig(:)*mxi
  dde=gosig(:)*mxe
  ddn=gosig(:)*mxn
  if (eeu(iqw).gt.0.5) then ! water
    sdi=2
    sde=2
    sdn=2
    sds=2
    sdne=2
    sdse=2
    mxs=dd(is(iqw))
    mxne=dd(ine(iqw))
    mxse=dd(ise(iqw))
    sss=rhobar(is(iqw),:)
    ssne=rhobar(ine(iqw),:)
    ssse=rhobar(ise(iqw),:)
    dds=gosig(:)*mxs
    ddne=gosig(:)*mxne
    ddse=gosig(:)*mxse
    do ii=1,wlev
      ! process staggered u locations
      ! estimate vertical gradient
      drhobardzu=(rhobarhl(iqw,ii)+rhobarhl(ie(iqw),ii)-rhobarhl(iqw,ii-1)-rhobarhl(ie(iqw),ii-1))          &
                /(dephladj(iqw,ii)+dephladj(ie(iqw),ii)-dephladj(iqw,ii-1)-dephladj(ie(iqw),ii-1))
      ! use scaled depths (i.e., assume neta is small compared to dd)
      ddux=gosig(ii)*ddu(iqw) ! seek depth
      if (mxi.lt.ddux.or.mxe.lt.ddux) then
        drhobardxu(iqw,ii)=0. ! assume zero gradient for bathymetry
      else
        call seekval(ri,ssi(:),ddi(:),ddux,sdi)
        call seekval(re,sse(:),dde(:),ddux,sde)
        ! the following terms correct for neglecting neta in the above intepolation of depths
        ri=ri+drhobardzu*(1.-gosig(ii))*neta(iqw)
        re=re+drhobardzu*(1.-gosig(ii))*neta(ie(iqw))
        drhobardxu(iqw,ii)=eeu(iqw)*(re-ri)*emu(iqw)/ds
      end if
      if (mxn.lt.ddux.or.mxne.lt.ddux.or.mxs.lt.ddux.or.mxse.lt.ddux) then
        drhobardyu(iqw,ii)=0. ! assume zero gradient for bathymetry
      else
        call seekval(rn,ssn(:),ddn(:),ddux,sdn)
        call seekval(rne,ssne(:),ddne(:),ddux,sdne)
        call seekval(rs,sss(:),dds(:),ddux,sds)
        call seekval(rse,ssse(:),ddse(:),ddux,sdse)
        ! the following terms correct for neglecting neta in the above interpolation of depths
        rn=rn+drhobardzu*(1.-gosig(ii))*neta(in(iqw))
        rne=rne+drhobardzu*(1.-gosig(ii))*neta(ine(iqw))
        rs=rs+drhobardzu*(1.-gosig(ii))*neta(is(iqw))
        rse=rse+drhobardzu*(1.-gosig(ii))*neta(ise(iqw))
        drhobardyu(iqw,ii)=stwgt(iqw,1)*0.25*(rn+rne-rs-rse)*emu(iqw)/ds
      end if
    end do
  else
    drhobardxu(iqw,:)=0.
    drhobardyu(iqw,:)=0.
  end if
  if (eev(iqw).gt.0.5) then ! water
    sdi=2
    sdn=2
    sde=2
    sdw=2
    sden=2
    sdwn=2
    mxw=dd(iw(iqw))
    mxen=dd(ien(iqw))
    mxwn=dd(iwn(iqw))
    ssw=rhobar(iw(iqw),:)
    ssen=rhobar(ien(iqw),:)
    sswn=rhobar(iwn(iqw),:)
    ddw=gosig(:)*mxw
    dden=gosig(:)*mxen
    ddwn=gosig(:)*mxwn
    do ii=1,wlev
      ! now process staggered v locations
      ! estimate vertical gradient
      drhobardzv=(rhobarhl(iqw,ii)+rhobarhl(in(iqw),ii)-rhobarhl(iqw,ii-1)-rhobarhl(in(iqw),ii-1))          &
                /(dephladj(iqw,ii)+dephladj(in(iqw),ii)-dephladj(iqw,ii-1)-dephladj(in(iqw),ii-1))
      ddvy=gosig(ii)*ddv(iqw) ! seek depth
      if (mxi.lt.ddvy.or.mxn.lt.ddvy) then
        drhobardyv(iqw,ii)=0. ! assume zero gradient for bathymetry
      else
        call seekval(ri,ssi(:),ddi(:),ddvy,sdi)
        call seekval(rn,ssn(:),ddn(:),ddvy,sdn)
        ri=ri+drhobardzv*(1.-gosig(ii))*neta(iqw)
        rn=rn+drhobardzv*(1.-gosig(ii))*neta(in(iqw))
        drhobardyv(iqw,ii)=eev(iqw)*(rn-ri)*emv(iqw)/ds
      end if
      if (mxe.lt.ddvy.or.mxen.lt.ddvy.or.mxw.lt.ddvy.or.mxwn.lt.ddvy) then
        drhobardxv(iqw,ii)=0. ! assume zero gradient for bathymetry
      else
        call seekval(re,sse(:),dde(:),ddvy,sde)
        call seekval(ren,ssen(:),dden(:),ddvy,sden)
        call seekval(rw,ssw(:),ddw(:),ddvy,sdw)
        call seekval(rwn,sswn(:),ddwn(:),ddvy,sdwn)
        re=re+drhobardzv*(1.-gosig(ii))*neta(ie(iqw))
        ren=ren+drhobardzv*(1.-gosig(ii))*neta(ien(iqw))
        rw=rw+drhobardzv*(1.-gosig(ii))*neta(iw(iqw))
        rwn=rwn+drhobardzv*(1.-gosig(ii))*neta(iwn(iqw))
        drhobardxv(iqw,ii)=stwgt(iqw,2)*0.25*(re+ren-rw-rwn)*emv(iqw)/ds
      end if
    end do
  else
    drhobardyv(iqw,:)=0.
    drhobardxv(iqw,:)=0. 
  end if
end do
 
return
end subroutine seekdelta

subroutine seekval(rout,ssin,ddin,ddseek,sindx)

use mlo, only : wlev

implicit none

integer, intent(inout) :: sindx
integer nindx
real, intent(in) :: ddseek
real, intent(out) :: rout
real, dimension(wlev), intent(in) :: ssin,ddin
real xp

do nindx=sindx,wlev
  if (ddin(nindx).ge.ddseek) exit
end do
sindx=min(nindx,wlev)

xp=(ddseek-ddin(sindx-1))/(ddin(sindx)-ddin(sindx-1))
xp=max(min(xp,1.),0.)

rout=ssin(sindx-1)+xp*(ssin(sindx)-ssin(sindx-1))

return
end subroutine seekval

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! POM style stencil for density gradient

subroutine pomdelta(rhobar,neta,drhobardxu,drhobardyu,drhobardxv,drhobardyv)

use indices_m
use map_m
use mlo, only : wlev,mindep

implicit none

include 'newmpar.h'
include 'parm.h'

integer ii
real, dimension(ifull+iextra,wlev), intent (in) :: rhobar
real, dimension(ifull+iextra), intent(in) :: neta
real, dimension(ifull,wlev), intent(out) :: drhobardxu,drhobardyu,drhobardxv,drhobardyv
real, dimension(ifull+iextra,0:wlev) :: rhobarhl,dephladj
real xp
real, dimension(ifull) :: rho1,rho2,rho3,rho4,z1,z2,z3,z4

! set-up level depths
dephladj(:,0)=0.
do ii=1,wlev
  dephladj(:,ii)=gosigh(ii)*max(dd(:)+neta(:),mindep)
end do

! estimate rhobar at half levels
rhobarhl(:,0)=rhobar(:,1)
do ii=1,wlev-1
  xp=gosigh(ii)-gosig(ii)
  rhobarhl(:,ii)=rhobar(:,ii)+xp*(rhobar(:,ii+1)-rhobar(:,ii))/(gosig(ii+1)-gosig(ii))
end do
rhobarhl(:,wlev)=rhobar(:,wlev)

! calculate gradients
do ii=1,wlev
  rho1=rhobarhl(ie,ii-1)
  rho2=rhobarhl(ie,ii)
  rho3=rhobarhl(1:ifull,ii-1)
  rho4=rhobarhl(1:ifull,ii)
  z1=dephladj(ie,ii-1)
  z2=dephladj(ie,ii)
  z3=dephladj(1:ifull,ii-1)
  z4=dephladj(1:ifull,ii)
  drhobardxu(:,ii)=0.5*((rho1+rho2-rho3-rho4)-(rho2-rho1+rho4-rho3)*(z1+z2-z3-z4)/(z2-z1+z4-z3))*emu(1:ifull)/ds
  drhobardxu(:,ii)=drhobardxu(:,ii)*eeu(1:ifull) 
  rho1=0.5*(rhobarhl(in,ii-1)+rhobarhl(ine,ii-1))
  rho2=0.5*(rhobarhl(in,ii)+rhobarhl(ine,ii))
  rho3=0.5*(rhobarhl(is,ii-1)+rhobarhl(ise,ii-1))
  rho4=0.5*(rhobarhl(is,ii)+rhobarhl(ise,ii))
  z1=0.5*(dephladj(in,ii-1)+dephladj(ine,ii-1))
  z2=0.5*(dephladj(in,ii)+dephladj(ine,ii))
  z3=0.5*(dephladj(is,ii-1)+dephladj(ise,ii-1))
  z4=0.5*(dephladj(is,ii)+dephladj(ise,ii))
  drhobardyu(:,ii)=stwgt(1:ifull,1)*0.25*((rho1+rho2-rho3-rho4)-(rho2-rho1+rho4-rho3)*(z1+z2-z3-z4)/(z2-z1+z4-z3))*emu(1:ifull)/ds
  rho1=0.5*(rhobarhl(ie,ii-1)+rhobarhl(ien,ii-1))
  rho2=0.5*(rhobarhl(ie,ii)+rhobarhl(ien,ii))
  rho3=0.5*(rhobarhl(iw,ii-1)+rhobarhl(iwn,ii-1))
  rho4=0.5*(rhobarhl(iw,ii)+rhobarhl(iwn,ii))
  z1=0.5*(dephladj(ie,ii-1)+dephladj(ien,ii-1))
  z2=0.5*(dephladj(ie,ii)+dephladj(ien,ii))
  z3=0.5*(dephladj(iw,ii-1)+dephladj(iwn,ii-1))
  z4=0.5*(dephladj(iw,ii)+dephladj(iwn,ii))
  drhobardxv(:,ii)=stwgt(1:ifull,2)*0.25*((rho1+rho2-rho3-rho4)-(rho2-rho1+rho4-rho3)*(z1+z2-z3-z4)/(z2-z1+z4-z3))*emv(1:ifull)/ds
  rho1=rhobarhl(in,ii-1)
  rho2=rhobarhl(in,ii)
  rho3=rhobarhl(1:ifull,ii-1)
  rho4=rhobarhl(1:ifull,ii)
  z1=dephladj(in,ii-1)
  z2=dephladj(in,ii)
  z3=dephladj(1:ifull,ii-1)
  z4=dephladj(1:ifull,ii)
  drhobardyv(:,ii)=0.5*((rho1+rho2-rho3-rho4)-(rho2-rho1+rho4-rho3)*(z1+z2-z3-z4)/(z2-z1+z4-z3))*emv(1:ifull)/ds
  drhobardyv(:,ii)=drhobardyv(:,ii)*eev(1:ifull) 
end do

return
end subroutine pomdelta

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Calculate tidal potential

subroutine mlotide(eta,slon,slat,mtimer,jstart)

implicit none

include 'newmpar.h'

integer i
integer, intent(in) :: mtimer,jstart
real, dimension(ifull), intent(out) :: eta
real, dimension(ifull), intent(in) :: slon,slat
real :: ltime,stime,ctime,mn,sn,pn
real, dimension(ifull) :: sinlon,coslon,sinlat,coslat
real, dimension(4) :: aa,ab,ba,bb
real, parameter :: pi = 3.1415927

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

eta=0.
eta=eta+ba(1)*aa(1)*sinlat*cos(ltime+mn-slon)             ! K1 (note sign change)
eta=eta-ba(2)*aa(2)*sinlat*cos(ltime-mn-slon)             ! O1
eta=eta-ba(3)*aa(3)*sinlat*cos(stime-sn-slon)             ! P1
eta=eta-ba(4)*aa(4)*sinlat*cos(ltime+pn-slon)             ! Q1
eta=eta-bb(1)*ab(1)*coslat*cos(2.*ltime-2.*slon)          ! M2
eta=eta-bb(2)*ab(2)*coslat*cos(2.*stime-2.*slon)          ! S2
eta=eta-bb(3)*ab(3)*coslat*cos(2.*ltime-mn+pn-2.*slon)    ! N2
eta=eta-bb(4)*ab(4)*coslat*cos(2.*stime+2.*sn-2.*slon)    ! K2

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
! this fill version is for a simply connected 2x2 grid
subroutine lfill(sc,sx)

implicit none

integer ncount
real, intent(in) :: sx
real, dimension(0:1,0:1), intent(inout) :: sc
real, dimension(0:1,0:1) :: nc
logical globc

ncount=count(sc.gt.-990.)

if (ncount.ge.4) return

if (ncount.le.0) then
  sc=sx
  return
end if

globc=.true.
nc=sc
do while(globc)
  globc=.false.
  call trial(nc,sc,0,0,.false.,.true.,.true.,.false.,globc)
  call trial(nc,sc,1,0,.false.,.false.,.true.,.true.,globc)
  call trial(nc,sc,0,1,.true.,.true.,.false.,.false.,globc)
  call trial(nc,sc,1,1,.true.,.false.,.false.,.true.,globc)
  sc=nc
end do

return
end subroutine lfill

! This routine averages adjacent points for an average fill
subroutine trial(nc,sc,i,j,ln,le,ls,lw,globc)

implicit none

integer, intent(in) :: i,j
integer nec
real, dimension(0:1,0:1), intent(inout) :: nc
real, dimension(0:1,0:1), intent(in) :: sc
real new
logical, intent(inout) :: globc
logical, intent(in) :: ln,le,ls,lw

if (nc(i,j).gt.-990.) return

new=0.
nec=0
if (ln) then
  if (sc(i,j-1).gt.-990.) then
    new=new+sc(i,j-1)
    nec=nec+1
  end if
end if
if (le) then
  if (sc(i+1,j).gt.-990.) then
    new=new+sc(i+1,j)
    nec=nec+1
  end if
end if
if (ls) then
  if (sc(i,j+1).gt.-990.) then
    new=new+sc(i,j+1)
    nec=nec+1
  end if
end if
if (lw) then
  if (sc(i-1,j).gt.-990.) then
    new=new+sc(i-1,j)
    nec=nec+1
  end if
end if
if (nec.gt.0) then
  nc(i,j)=new/real(nec)
else
  globc=.true.
end if
  
return
end subroutine trial

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! test for leap year

subroutine mloleap(tyear,ttest)

implicit none

integer, intent(in) :: tyear
logical, intent(out) :: ttest

ttest=.false.
if (mod(tyear,4).eq.0)   ttest=.true.
if (mod(tyear,100).eq.0) ttest=.false.
if (mod(tyear,400).eq.0) ttest=.true.

return
end subroutine mloleap

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Advect ice using upwind scheme

subroutine upwindadv(dumc,niu,niv,spnet)

use indices_m
use map_m

implicit none

include 'newmpar.h'
include 'parm.h'

real, dimension(ifull+iextra), intent(inout) :: dumc
real, dimension(ifull+iextra), intent(in) :: niu,niv,spnet
real, dimension(ifull) :: odum,dumd 

dumd=dumc(1:ifull)
odum=0.5*dt*(niu(iwu)*(dumc(1:ifull)+dumc(iw))    -abs(niu(iwu))*(dumc(1:ifull)-dumc(iw))    )*emu(iwu)/ds
where (spnet(iw).gt.0.)
  odum=min(odum,dumc(iw)*max(niu(iwu),0.)/spnet(iw))
end where
where (spnet(1:ifull).gt.0.)
  odum=max(odum,dumc(1:ifull)*min(niu(iwu),0.)/spnet(1:ifull))
end where
dumd=dumd+odum
odum=-0.5*dt*(niu(1:ifull)*(dumc(1:ifull)+dumc(ie))+abs(niu(1:ifull))*(dumc(1:ifull)-dumc(ie)))*emu(1:ifull)/ds
where (spnet(ie).gt.0.)
  odum=min(odum,-dumc(ie)*min(niu(1:ifull),0.)/spnet(ie))
end where
where (spnet(1:ifull).gt.0.)
  odum=max(odum,-dumc(1:ifull)*max(niu(1:ifull),0.)/spnet(1:ifull))
end where
dumd=dumd+odum  
odum=0.5*dt*(niv(isv)*(dumc(1:ifull)+dumc(is))    -abs(niv(isv))*(dumc(1:ifull)-dumc(is))    )*emv(isv)/ds
where (spnet(is).gt.0.)
  odum=min(odum,dumc(is)*max(niv(isv),0.)/spnet(is))
end where
where (spnet(1:ifull).gt.0.)
  odum=max(odum,dumc(1:ifull)*min(niv(isv),0.)/spnet(1:ifull))
end where
dumd=dumd+odum
odum=-0.5*dt*(niv(1:ifull)*(dumc(1:ifull)+dumc(in))+abs(niv(1:ifull))*(dumc(1:ifull)-dumc(in)))*emv(1:ifull)/ds
where (spnet(in).gt.0.)
  odum=min(odum,-dumc(in)*min(niv(1:ifull),0.)/spnet(in))
end where
where (spnet(1:ifull).gt.0.)
  odum=max(odum,-dumc(1:ifull)*max(niv(1:ifull),0.)/spnet(1:ifull))
end where
dumd=dumd+odum
dumc(1:ifull)=dumd
dumc(1:ifull)=max(dumc(1:ifull),0.)
  
return
end subroutine upwindadv

end module mlodynamics
