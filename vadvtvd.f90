! Conformal Cubic Atmospheric Model
    
! Copyright 2015-2021 Commonwealth Scientific Industrial Research Organisation (CSIRO)
    
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

!     split vertical advection routine; tvd scheme; used with nonlin or upglobal
!     In flux limiter, assuming zero gradient for all top and bottom
!     variables; except extrap at bottom for qg and trace gases  Thu  06-19-1997
    
module vadv
      
private
public vadvtvd
      
contains

subroutine vadvtvd(tarr,uarr,varr,nvadh_pass,nits)

use aerosolldr
use arrays_m
use cc_mpi
use cfrac_m, only : stratcloud
use diag_m
use liqwpar_m  ! ifullw
use map_m
use newmpar_m
use nharrs_m
use parm_m
use parmdyn_m
use sigs_m
use tkeeps, only : tke,eps
use tracers_m
use vvel_m
use xarrs_m

implicit none

include 'kuocom.h'     ! also with kbsav,ktsav

integer ntr,k
integer, dimension(ifull) :: nvadh_pass, nits
integer, save :: num = 0
real, dimension(:,:), intent(inout) :: tarr,uarr,varr

call START_LOG(vadv_begin)

if ( num==0 ) then
  num = 1
  if ( mydiag ) then
    write(6,*) 'In vadvtvd nvadh_pass ',nvadh_pass(idjd)
  end if
end if

!$omp parallel sections

!$omp section
!     t
call vadv_work(tarr,nvadh_pass,nits)

!     u
call vadv_work(uarr,nvadh_pass,nits)

!     v
call vadv_work(varr,nvadh_pass,nits)
if( diag .and. mydiag )then
!       These diagnostics don't work with single input/output argument
  write (6,"('tout',9f8.2/4x,9f8.2)") (tarr(idjd,k),k=1,kl)
  write (6,"('t#  ',9f8.2)") diagvals(tarr(:,nlv)) 
  write (6,"('uout',9f8.2/4x,9f8.2)") (uarr(idjd,k),k=1,kl)
  write (6,"('u#  ',9f8.2)") diagvals(uarr(:,nlv)) 
  write (6,"('vout',9f8.2/4x,9f8.2)") (varr(idjd,k),k=1,kl)
  write (6,"('v#  ',9f8.2)") diagvals(varr(:,nlv)) 
endif

!$omp section
!     h_nh
if ( nh/=0 ) then
  call vadv_work(h_nh,nvadh_pass,nits)
end if

!     pslx
call vadv_work(pslx,nvadh_pass,nits)

!      qg
if ( mspec==1 ) then   ! advect qg and gases after preliminary step
  call vadv_work(qg,nvadh_pass,nits)
  if ( diag .and. mydiag ) then
    write (6,"('qout',9f8.2/4x,9f8.2)") (1000.*qg(idjd,k),k=1,kl)
    write (6,"('qg# ',9f8.2)") diagvals(qg(:,nlv)) 
  end if
end if          ! if(mspec==1)

!$omp section
if ( mspec==1 ) then   ! advect qg and gases after preliminary step
  if ( ldr/=0 ) then
    call vadv_work(qlg,nvadh_pass,nits)
    call vadv_work(qfg,nvadh_pass,nits)
    call vadv_work(stratcloud,nvadh_pass,nits)
    if ( diag .and. mydiag ) then
      write (6,"('lout',9f8.2/4x,9f8.2)") (1000.*qlg(idjd,k),k=1,kl)
      write (6,"('qlg#',9f8.2)") diagvals(qlg(:,nlv)) 
      write (6,"('fout',9f8.2/4x,9f8.2)") (1000.*qfg(idjd,k),k=1,kl)
      write (6,"('qfg#',9f8.2)") diagvals(qfg(:,nlv)) 
    end if
  end if      ! if(ldr.ne.0)
end if        ! if(mspec==1)

!$omp section
if ( mspec==1 ) then   ! advect qg and gases after preliminary step
  if ( nvmix==6 .or. nvmix==9 ) then
    call vadv_work(eps,nvadh_pass,nits)
    call vadv_work(tke,nvadh_pass,nits)
  end if      ! if(nvmix==6 .or. nvmix==9 )
end if          ! if(mspec==1)

!$omp end parallel sections

if ( mspec==1 ) then   ! advect qg and gases after preliminary step
    
  if ( abs(iaero)>=2 ) then
    !$omp parallel do private(ntr)  
    do ntr = 1,naero
      call vadv_work(xtg(:,:,ntr),nvadh_pass,nits)
    end do
    !$omp end parallel do
  end if   ! abs(iaero)>=2
  
  if ( ngas>0 .or. nextout>=4 ) then
    !$omp parallel do private(ntr)  
    do ntr = 1,ntrac
      call vadv_work(tr(:,:,ntr),nvadh_pass,nits)
    end do
    !$omp end parallel do
  end if        ! (nextout>=4)
  
end if          ! if(mspec==1)

call END_LOG(vadv_end)
 
return
end subroutine vadvtvd
      
! Subroutine to perform generic TVD advection
subroutine vadv_work(tarr,nvadh_pass,nits)

use newmpar_m
use sigs_m
use vvel_m
      
implicit none
      
integer, dimension(ifull), intent(in) :: nits, nvadh_pass
integer i, k, iq, kp, kx
real, dimension(:,:), intent(inout) :: tarr
real rat, phitvd, fluxhi, fluxlo
real, dimension(ifull,0:kl) :: delt, fluxh

! The first sub-step is vectorised for all points - MJT

!     fluxh(k) is located at level k+.5
do k = 1,kl-1
  do iq = 1,ifull
    delt(iq,k) = tarr(iq,k+1) - tarr(iq,k)
  end do
end do  
do iq = 1,ifull
  fluxh(iq,0)  = 0.
  fluxh(iq,kl) = 0.
  delt(iq,kl)  = 0.     ! for T,u,v
  delt(iq,0)   = 0.
  !!delt(iq,0)   = min(delt(iq,1), tarr(iq,1))       ! for non-negative tt
end do

do k = 1,kl-1  ! for fluxh at interior (k + 1/2)  half-levels
  do iq = 1,ifull      
    kp = nint(sign(1.,sdot(iq,k+1)))
    kx = k + (1-kp)/2 !  k for sdot +ve,  k+1 for sdot -ve
    rat = delt(iq,k-kp)/(delt(iq,k)+sign(1.e-20,delt(iq,k)))
    fluxlo = tarr(iq,kx)
    phitvd = max(0., min(2.*rat,.5+.5*rat, 2.))    ! 0 for -ve rat
    ! higher order scheme
    fluxhi = rathb(k)*tarr(iq,k) + ratha(k)*tarr(iq,k+1) - .5*delt(iq,k)*sdot(iq,k+1)/real(nvadh_pass(iq))
    fluxh(iq,k) = sdot(iq,k+1)*(fluxlo+phitvd*(fluxhi-fluxlo))
  enddo
enddo      ! k loop
do k = 1,kl
  do iq = 1,ifull
    tarr(iq,k) = tarr(iq,k) + (fluxh(iq,k-1)-fluxh(iq,k) &
                             +tarr(iq,k)*(sdot(iq,k+1)-sdot(iq,k)))/real(nvadh_pass(iq))
  end do
end do

do iq = 1,ifull 
  do i = 2,nits(iq)
    do k = 1,kl-1
      delt(iq,k) = tarr(iq,k+1) - tarr(iq,k)
    end do     ! k loop    
    !!delt(iq,0) = min(delt(iq,1), tarr(iq,1))       ! for non-negative tt
    do k = 1,kl-1  ! for fluxh at interior (k + 1/2)  half-levels
      kp = nint(sign(1.,sdot(iq,k+1)))
      kx = k + (1-kp)/2 !  k for sdot +ve,  k+1 for sdot -ve
      rat = delt(iq,k-kp)/(delt(iq,k)+sign(1.e-20,delt(iq,k)))
      fluxlo = tarr(iq,kx)
      phitvd = max(0., min(2.*rat, .5+.5*rat, 2.))   ! 0 for -ve rat
      ! higher order scheme
      fluxhi = rathb(k)*tarr(iq,k) + ratha(k)*tarr(iq,k+1) - .5*delt(iq,k)*sdot(iq,k+1)/real(nvadh_pass(iq))
      fluxh(iq,k) = sdot(iq,k+1)*(fluxlo+phitvd*(fluxhi-fluxlo))
    end do ! k
    do k = 1,kl
      tarr(iq,k) = tarr(iq,k) &
          + (fluxh(iq,k-1)-fluxh(iq,k)+tarr(iq,k)*(sdot(iq,k+1)-sdot(iq,k)))/real(nvadh_pass(iq))
    end do
  end do   ! i
end do     ! iq

return
end subroutine vadv_work

end module vadv
