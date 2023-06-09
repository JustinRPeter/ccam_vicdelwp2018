module tfcom_m

implicit none

private
public to3,co21,emiss,emiss2,avephi,cts,ctso3
public excts,exctsn,e1flx,co2nbl,co2sp1,co2sp2
public co2sp,to3spc,totvo2
public tfcom_init,tfcom_end

real, dimension(:,:,:), allocatable, save :: to3,co21,emiss,emiss2,avephi,exctsn
real, dimension(:,:), allocatable, save :: cts,ctso3,excts
real, dimension(:,:), allocatable, save :: e1flx,co2nbl,co2sp1,co2sp2
real, dimension(:,:), allocatable, save :: co2sp,to3spc,totvo2

contains

subroutine tfcom_init(ifull,iextra,kl,imax,nbly)

implicit none

integer, intent(in) :: ifull,iextra,kl,imax,nbly

allocate(to3(imax,kl+1,kl+1),co21(imax,kl+1,kl+1),emiss(imax,kl+1,kl+1),emiss2(imax,kl+1,kl+1),avephi(imax,kl+1,kl+1))
allocate(cts(imax,kl),ctso3(imax,kl),excts(imax,kl),exctsn(imax,kl,nbly))
allocate(e1flx(imax,kl+1),co2nbl(imax,kl),co2sp1(imax,kl+1),co2sp2(imax,kl+1))
allocate(co2sp(imax,kl+1),to3spc(imax,kl),totvo2(imax,kl+1))

return
end subroutine tfcom_init

subroutine tfcom_end

implicit none

deallocate(to3,co21,emiss,emiss2,avephi,cts,ctso3)
deallocate(excts,exctsn,e1flx,co2nbl,co2sp1,co2sp2)
deallocate(co2sp,to3spc,totvo2)

return
end subroutine tfcom_end

end module tfcom_m