! Conformal Cubic Atmospheric Model
    
! Copyright 2015 Commonwealth Scientific Industrial Research Organisation (CSIRO)
    
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

module hs_phys_m

implicit none

private
public hs_phys_init,hs_phys

integer, save :: nb, imax

contains

subroutine hs_phys_init(ifull,nbin)

implicit none
integer, intent(in) :: ifull,nbin

nb=nbin
imax=ifull/nb

end subroutine hs_phys_init

subroutine hs_phys

implicit none
integer :: i

!$omp parallel do
do i=1,nb
  call hs_phys_work(i)
end do

end subroutine hs_phys

!------------------------------------------------------------------------------
    
! from July 2006, use split scheme
!  version for globpex with tendencies
!  This is a simplified physics routine implementing the temperature
!  relaxation and wind drag for Held-Suarez dynamical core experiments. 
!  The drag coefficient depends on height and the temperature relaxation
!  time depends on latitude and height.

!  The equilibrium temperature depends only on latitude and height, but on 
!  the conformal-cubic grid this requires a full 3D array. To save this
!  it's recalculated for each point.

subroutine hs_phys_work(tile)

use arrays_m, only : t,u,v
use latlong_m, only : rlatt
use newmpar_m, only : kl
use parm_m, only : dt
use sigs_m, only : sig

implicit none

integer, intent(in) :: tile
integer k
!     All coefficients are in units of inverse days
real, parameter :: invday=1./86400.
real, parameter :: kf = 1. * invday
real, parameter :: ks = 0.25 * invday
real, parameter :: ka = 0.025 * invday
real, parameter :: sig_b = 0.7    ! Drag applied below this level
real, parameter :: delty = 60.    ! Pole to equator variation in equil temperature
real, parameter :: deltheta = 10. ! Vertical variation
real, parameter :: kappa = 2./7.
real kv
real, dimension(imax) :: kt, teq
integer :: is,ie

is=(tile-1)*imax+1
ie=tile*imax

do k=1,kl 
  kt = ka + (ks-ka)*max(0., (sig(k)-sig_b)/(1.-sig_b)) * cos(rlatt(is:ie))**4
  teq = max ( 200., (315. - delty*sin(rlatt(is:ie))**2 - deltheta*log(sig(k))*cos(rlatt(is:ie))**2)*sig(k)**kappa )
  t(is:ie,k) = (t(is:ie,k)*(1.-.5*dt*kt(:))+dt*kt(:)*teq(:))/(1.+.5*dt*kt(:))  ! implicit form

  ! Winds have a height dependent drag
  kv = kf * max(0., (sig(k)-sig_b)/(1.-sig_b))
  u(is:ie,k) = u(is:ie,k)*(1.-.5*dt*kv)/(1.+.5*dt*kv) ! im form
  v(is:ie,k) = v(is:ie,k)*(1.-.5*dt*kv)/(1.+.5*dt*kv) ! im form
end do

return
end subroutine hs_phys_work

end module hs_phys_m
