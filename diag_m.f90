module diag_m
   implicit none
   public :: printa, maxmin, average, diagvals
   private :: maxmin1, maxmin2, printa1, printa2
   interface maxmin
      module procedure maxmin1, maxmin2
   end interface
   interface printa
      module procedure printa1, printa2
   end interface
   interface diagvals
      module procedure diagvals_r, diagvals_i, diagvals_l
   end interface
contains
   subroutine printa2(name,a,ktau,level,i1,i2,j1,j2,bias,facti)
      ! printa has to work with arrays dimension both ifull and ifull+iextra
      ! printb has printj entry, and automatic choice of fact if facti=0.
      ! Have both 1D and multi-level versions.
      use cc_mpi
      include 'newmpar.h'
      character(len=*), intent(in) :: name
      real, dimension(:,:), intent(in) :: a
      integer, intent(in) :: ktau, level, i1, i2, j1, j2
      real, intent(in) :: bias, facti

      call printa1(name,a(:,level),ktau,level,i1,i2,j1,j2,bias,facti)
   end subroutine printa2

   subroutine printa1(name,a,ktau,level,i1,i2,j1,j2,bias,facti)
      ! printa has to work with arrays dimension both ifull and ifull+iextra
      ! printb has printj entry, and automatic choice of fact if facti=0.
      ! Have both 1D and multi-level versions.
      use cc_mpi
      include 'newmpar.h'
      character(len=*), intent(in) :: name
      real, dimension(:), intent(in) :: a
      integer, intent(in) :: ktau, level, i1, i2, j1, j2
      real, intent(in) :: bias, facti
      integer i, j, ja, jb, n, n2, ilocal, jlocal, nlocal
      real fact, atmp

      ! The indices i1, i2, j1, j2 are global
      n = (j1-1)/il_g ! Global n
      j = j1 - n*il_g ! Value on face
      if ( myid == fproc(i1,j,n) ) then
         ! Check if whole region is on this processor
         n2 = (j2-1)/il_g
         if ( fproc(i2, j2-n2*il_g, n2) /= myid ) then
           write(0,*)"Warning, printa region covers more than one processor"
           return    
         end if
         ja=j1
         jb=min(ja+24,j2)
         fact=facti
         ! Calculate factor from the middle of the face 
         ! This will be consistent for 1-6 processors at least
         nlocal = n + noff
         if(facti.eq.0.) then
            atmp = abs(a(indp(ipan/2,jpan/2,nlocal)))
            if ( atmp > 0 ) then
               fact = 10./atmp
            else 
               fact = 1.0
            end if
         end if
         print 9 ,name,ktau,level,bias,fact
 9       format(/1x,a4,' ktau =',i7,'  level =',i3,'  addon =',g8.2,   &      
     & '  has been mult by',1pe8.1)
         print 91,(j,j=j1,j2)
91       format(4x,25i11)
         do i=i1,i2
            write(unit=*,fmt="(i5)", advance="no") i
            do j=ja,jb
               n = (j-1)/il_g ! Global n
               nlocal = n + noff
               ilocal = i - ioff(n)
               jlocal = j - n*il_g - joff(n)
               write(unit=*,fmt="(f11.6)", advance="no")                &
     &              (a(indp(ilocal,jlocal,nlocal))-bias)*fact
            end do
            write(*,*)
         end do
      end if

   end subroutine printa1

! has more general format & scaling factor  with subroutine average at bottom
   subroutine maxmin2(u,char,ktau,fact,kup)
      use cc_mpi
      include 'newmpar.h'
      character(len=2), intent(in) :: char
      integer, intent(in) :: ktau, kup
      real, intent(in) :: fact
      real, dimension(:,:), intent(in) :: u
      real, dimension(2,kup) :: umin, umax
      integer, dimension(2,kup) :: ijumax,ijumin
      integer, dimension(1) :: imax,imin
      integer :: iqg
      integer :: i, j, k, ierr
      ! gumax(1,:) is true maximum, gumax(2,:) used for the location
      real, dimension(2,kl) :: gumax, gumin
      real gmax, gmin

      do k=1,kup
         umax(1,k) = maxval(u(1:ifull,k))
         umin(1,k) = minval(u(1:ifull,k))
         ! Simpler to use real to hold the integer location. 
         ! No rounding problem for practical numbers of points
         ! Convert this to a global index
         !-----------------------------------------------------------
         ! MJT bug fix
         !umax(2,k) = maxloc(u(1:ifull,k),dim=1) + myid*ifull
         !umin(2,k) = minloc(u(1:ifull,k),dim=1) + myid*ifull
         imax=maxloc(u(1:ifull,k),dim=1)
         imin=minloc(u(1:ifull,k),dim=1)
         umax(2,k)=real(iq2iqg(imax(1)))
         umin(2,k)=real(iq2iqg(imin(1)))         
         !-----------------------------------------------------------  
      end do

      call ccmpi_reduce(umax,gumax,"maxloc",0,comm_world)
      call ccmpi_reduce(umin,gumin,"minloc",0,comm_world)

      if ( myid == 0 ) then
      
         do k=1,kup
            iqg = gumax(2,k)
            ! Convert to global i, j indices
            j = 1 + (iqg-1)/il_g
            i = iqg - (j-1)*il_g
            ijumax(:,k) = (/ i, j /)
            iqg = gumin(2,k)
            j = 1 + (iqg-1)/il_g
            i = iqg - (j-1)*il_g
            ijumin(:,k) = (/ i, j /)
         end do
         
        if(fact==0.)then
          gmax=-1.e20
          gmin=1.e20
          do k=1,kup
           gmax=max(gmax,gumax(1,k))
           gmin=min(gmin,gumin(1,k))
          enddo
          print *,char,'Gmax,Gmin ',gmax,gmin
          if(gmax==0.)gmax=1.
          if(gmin==0.)gmin=1.
          print 981,ktau,char,gumax(1,1:10)/abs(gmax),     &
     &                   char,gumax(1,11:kup)/abs(gmax)
          print 977,ktau,ijumax
          print 982,ktau,char,gumin(1,:)/abs(gmin)
          print 977,ktau,ijumin
          return
        endif  ! (fact==0.)
        
        gumax(1,:)=gumax(1,:)*fact
        gumin(1,:)=gumin(1,:)*fact

       if(kup.eq.1)then
        print 970,ktau,char,gumax(1,1),char,gumin(1,1)
970     format(i7,1x,a2,'max ',f8.3,3x,a2,'min ',f8.3)
        print 9705,ktau,ijumax(:,1),ijumin(:,1)
9705    format(i7,'  posij',i4,i4,10x,i3,i4)
        return
       endif   !  (kup.eq.1)

       if(gumax(1,1).ge.1000.)then   ! for radon
        print 961,ktau,char,gumax(1,:)
961     format(i7,1x,a2,'max ',10f7.1/(14x,10f7.1)/(14x,10f7.1))
        print 977,ktau,ijumax
        print 962,ktau,char,gumin(1,:)
962     format(i7,1x,a2,'min ',10f7.1/(14x,10f7.1)/(14x,10f7.1))
        print 977,ktau,ijumin
       elseif(kup.le.10)then  ! format for tggsn
        print 971,ktau,char,(gumax(1,k),k=1,kup)
        print 977,ktau,ijumax
        print 972,ktau,char,(gumin(1,k),k=1,kup)
        print 977,ktau,ijumin
       elseif(gumax(1,kup).gt.30.)then  ! format for T, & usually u,v
        print 971,ktau,char,gumax(1,1:10),char,gumax(1,11:kup)
!!!971  format(i7,1x,a2,'max ',10f7.2/(14x,10f7.2)/(14x,10f7.2))
971     format(i7,1x,a2,'max ',10f7.2/(a10,'maX ',10f7.2)/(14x,10f7.2))
        print 977,ktau,ijumax
        print 972,ktau,char,gumin(1,:)
972     format(i7,1x,a2,'min ',10f7.2/(14x,10f7.2)/(14x,10f7.2))
        print 977,ktau,ijumin
977     format(i7,'  posij',10(i3,i4)/(14x,10(i3,i4))/(14x,10(i3,i4)))
       else  ! for qg & sd
        print 981,ktau,char,gumax(1,1:10),char,gumax(1,11:kup)
981     format(i7,1x,a2,'max ',10f7.3/(a10,'maX ',10f7.3)/(14x,10f7.3))
        print 977,ktau,ijumax
        print 982,ktau,char,gumin(1,:)
982     format(i7,1x,a2,'min ',10f7.3/(14x,10f7.3)/(14x,10f7.3))
        print 977,ktau,ijumin
       endif
      endif ! myid == 0
      return
   end subroutine maxmin2

   subroutine maxmin1(u,char,ktau,fact,kup)
      use cc_mpi
      include 'newmpar.h'
      character(len=2), intent(in) :: char
      integer, intent(in) :: ktau, kup
      real, intent(in) :: fact
      real, dimension(:), intent(in) :: u
      real, dimension(2) :: umin, umax
      integer, dimension(2) :: ijumax,ijumin
      integer, dimension(1) :: imax,imin
      integer ierr, i, j
      integer :: iqg
      real, dimension(2) :: gumax, gumin


      umax(1) = maxval(u(1:ifull))*fact
      umin(1) = minval(u(1:ifull))*fact
      !-----------------------------------------------------------
      ! MJT bug fix
      !umax(2) = maxloc(u(1:ifull),dim=1) + myid*ifull
      !umin(2) = minloc(u(1:ifull),dim=1) + myid*ifull
      imax=maxloc(u(1:ifull),dim=1)
      imin=minloc(u(1:ifull),dim=1)
      umax(2)=real(iq2iqg(imax(1)))
      umin(2)=real(iq2iqg(imin(1)))
      !-----------------------------------------------------------
      call ccmpi_reduce(umax,gumax,"maxloc",0,comm_world)
      call ccmpi_reduce(umin,gumin,"minloc",0,comm_world)

      if ( myid == 0 ) then
        iqg = gumax(2)
        ! Convert to global i, j indices
        j = 1 + (iqg-1)/il_g
        i = iqg - (j-1)*il_g
        ijumax(:) = (/ i, j /)
        iqg = gumin(2)
        j = 1 + (iqg-1)/il_g
        i = iqg - (j-1)*il_g
        ijumin(:) = (/ i, j /)

        print 970,ktau,char,gumax(1),char,gumin(1)
970     format(i7,1x,a2,'max ',f8.3,3x,a2,'min ',f8.3)
        print 9705,ktau,ijumax,ijumin
9705    format(i7,'  posij',i4,i4,10x,i3,i4)
      end if ! myid == 0
      return
   end subroutine maxmin1

   subroutine average(speed,spmean_g,spavge_g)
      use cc_mpi
      use sigs_m
      use sumdd_m
      use xyzinfo_m
      include 'newmpar.h'
      real, dimension(:,: ), intent(in) :: speed
      real, dimension(:), intent(out) :: spmean_g
      real, intent(out) :: spavge_g
      real, dimension(kl) :: spmean
      real, dimension(size(speed,1)) :: tmpb
      complex, dimension(kl) :: tmpc,tmpc_g
      integer k, iq, ierr
      
      tmpc=(0.,0.)
      do k=1,kl
         tmpb=speed(1:ifull,k)*wts(1:ifull)
         call drpdr_local(tmpb,tmpc(k))
      end do
#ifdef sumdd
      call ccmpi_reduce(tmpc,tmpc_g,"sumdr",0,comm_world)
      spmean_g=real(tmpc_g)
#else
      do k=1,kl
         spmean(k)=real(tmpc(k))
      end do
      call ccmpi_reduce(spmean,spmean_g,"sum",0,comm_world)
#endif      
      spavge_g = 0.0
      do k=1,kl
         spavge_g = spavge_g-dsig(k)*spmean_g(k) ! dsig is -ve
      end do

   end subroutine average

   function diagvals_r(a) result (res)
      use cc_mpi
      include 'newmpar.h'
      include 'parm.h'
      real, intent(in), dimension(:) :: a
      real, dimension(9) :: res
      integer :: i, j, n, jf, ilocal, jlocal, nloc, iq

!     Return the equivalent of arr(ii+(jj-1)*il),ii=id-1,id+1),jj=jd-1,jd+1)
!     Note that this doesn't get off-processor values correctly!
!     Restrict range so that it still works if id=1 etc
      iq = 0
      res = 0. ! As a sort of missing value
      do j=min(jd-1,jl_g),max(jd+1,1)
         do i=max(id-1,1),min(id+1,il_g)
            iq = iq + 1
            n = (j-1)/il_g  ! Global n
            jf = j - n*il_g ! Value on face
            if ( fproc(i, jf, n) == myid ) then
               nloc = n + noff
               ilocal = i - ioff(n)
               jlocal = j - n*il_g - joff(n)
               res(iq) = a(indp(ilocal,jlocal,nloc))
            end if
         end do
      end do
   end function diagvals_r

   function diagvals_i(a) result (res)
      use cc_mpi
      include 'newmpar.h'
      include 'parm.h'
      integer, intent(in), dimension(:) :: a
      integer, dimension(9) :: res
      integer :: i, j, n, jf, ilocal, jlocal, nloc, iq

!     Return the equivalent of arr(ii+(jj-1)*il),ii=id-1,id+1),jj=jd-1,jd+1)
      iq = 0
      res = 0
      do j=max(jd-1,1),min(jd+1,jl_g)
         do i=max(id-1,1),min(id+1,il_g)
            iq = iq + 1
            n = (j-1)/il_g  ! Global n
            jf = j - n*il_g ! Value on face
            if ( fproc(i, jf, n) == myid ) then
               nloc = n + noff
               ilocal = i - ioff(n)
               jlocal = j - n*il_g - joff(n)
               res(iq) = a(indp(ilocal,jlocal,nloc))
            end if
         end do
      end do
   end function diagvals_i

   function diagvals_l(a) result (res)
      use cc_mpi
      include 'newmpar.h'
      include 'parm.h'
      logical, intent(in), dimension(:) :: a
      logical, dimension(9) :: res
      integer :: i, j, n, jf, ilocal, jlocal, nloc, iq

!     Return the equivalent of arr(ii+(jj-1)*il),ii=id-1,id+1),jj=jd-1,jd+1)
      iq = 0
      res = .false.
      do j=max(jd-1,1),min(jd+1,jl_g)
         do i=max(id-1,1),min(id+1,il_g)
            iq = iq + 1
            n = (j-1)/il_g  ! Global n
            jf = j - n*il_g ! Value on face
            if ( fproc(i, jf, n) == myid ) then
               nloc = n + noff
               ilocal = i - ioff(n)
               jlocal = j - n*il_g - joff(n)
               res(iq) = a(indp(ilocal,jlocal,nloc))
            end if
         end do
      end do
   end function diagvals_l

end module diag_m
