! Dummy MPI routines for running a single processor version on a machine
! without MPI.

subroutine MPI_Init(ierr)
   integer, intent(out) :: ierr
   ierr = 0
end subroutine MPI_Init

subroutine MPI_Comm_size(comm, nproc, ierr)
   integer, intent(in) :: comm
   integer, intent(out) :: nproc, ierr
   nproc = 1
   ierr = 0
end subroutine MPI_Comm_size

subroutine MPI_Comm_rank(comm, myid, ierr)
   integer, intent(in) :: comm
   integer, intent(out) :: myid, ierr
   myid = 0
   ierr = 0
end subroutine MPI_Comm_rank

subroutine MPI_Abort(comm,ierr2,ierr)
   integer :: comm, ierr,ierr2
   stop
end subroutine MPI_Abort

subroutine MPI_Finalize(ierr)
   integer, intent(out) :: ierr
   ierr = 0
end subroutine MPI_Finalize

subroutine MPI_Bcast(x,n,type,proc,comm,ierr)
   ! No work required
   real :: x
   integer :: n,type,proc,comm,ierr
   ierr = 0
end subroutine MPI_Bcast

subroutine MPI_Reduce ( xin, xout, n, type, op, proc, comm, ierr )
   ! Just copy input to output
   implicit none
   include 'mpif.h'
   integer ::  n, type, op, proc, comm, ierr
   real, dimension(*) :: xin, xout
   if ( type == MPI_2REAL ) then
      xout(1:2*n) = xin(1:2*n)
   else
      xout(1:n) = xin(1:n)
   end if
   ierr = 0
end subroutine MPI_Reduce

subroutine MPI_Allreduce ( xin, xout, n, type, op, comm, ierr )
   ! Just copy input to output
   integer ::  n, type, op, comm, ierr
   real, dimension(n) :: xin, xout
   xout = xin
   ierr = 0
end subroutine MPI_Allreduce

subroutine MPI_barrier(comm, ierr)
   integer :: comm, ierr
   ierr = 0
end subroutine MPI_barrier

double precision function MPI_Wtime()
   MPI_Wtime = 0.0
end function MPI_Wtime

double precision function MPI_Wtick()
   MPI_Wtick = 0.0
end function MPI_Wtick

subroutine MPI_Scatter( sbuf, a, type, rbuf, c, d, iproc, e, ierr )
   implicit none
   include 'mpif.h'   
   real, dimension(*) :: sbuf,rbuf
   integer :: a,type,c,d,e,iproc,ierr
   if ( type == MPI_DOUBLE_PRECISION ) then
      rbuf(1:2*a)=sbuf(1:2*a)
   else
      rbuf(1:a)=sbuf(1:a)
   end if
   ierr = 0
end subroutine MPI_Scatter

subroutine MPI_Gather( sbuf, a, b, rbuf, c, d, iproc, e, ierr )
   real, dimension(*) :: sbuf,rbuf
   integer :: a,b,c,d,e,iproc
   rbuf(1:a)=sbuf(1:a)
   ierr = 0
end subroutine MPI_Gather
 
subroutine MPI_Allgather( sbuf, a, b, rbuf, c, d, e, ierr )
   real, dimension(*) :: sbuf,rbuf
   integer :: a,b,c,d,e,iproc
   rbuf(1:a)=sbuf(1:a)
   ierr = 0
end subroutine MPI_Allgather 
 
subroutine MPI_Comm_Split(a, b, c, d, ierr)
   d=a
   ierr=0
end subroutine MPI_Comm_Split
 
subroutine MPI_Comm_Free(a,ierr)
   integer :: a,ierr
end subroutine MPI_Comm_Free

! Note of the following routines should be called in the 1 proc version.
subroutine MPI_Waitall(nreq,ireq,status,ierr)
   integer :: nreq,ierr
   integer, dimension(*) :: ireq,status
end subroutine MPI_Waitall

subroutine MPI_Waitany(nreq,ireq,indx,status,ierr)
   print*, "Error, dummy MPI_Waitany called"
   stop
end subroutine MPI_Waitany

subroutine MPI_Waitsome(nreq,ireq,len,list,status,ierr)
   print*, "Error, dummy MPI_Waitsome called"
   stop
end subroutine MPI_Waitsome

subroutine MPI_Recv( a, b, c, iproc, itag, d, status, ierr )
   print*, "Error, dummy MPI_Recv called"
   stop
end subroutine MPI_Recv

subroutine MPI_Irecv( a, b, c, iproc, itag, d, status, ierr )
   print*, "Error, dummy MPI_Irecv called"
   stop
end subroutine MPI_Irecv

subroutine MPI_Send
   print*, "Error, dummy MPI_Send called"
   stop
end subroutine MPI_Send

subroutine MPI_Isend( a, b, c, iproc, itag, d, status, ierr )
   print*, "Error, dummy MPI_Isend called"
   stop
end subroutine MPI_Isend

subroutine MPI_Ssend( sbuf, a, b, iproc, itag, c, ierr )
   print*, "Error, dummy MPI_Ssend called"
   stop
end subroutine MPI_Ssend

subroutine MPI_Get_count(status, a, count, ierr)
   print*, "Error, dummy MPI_Get_count called"
   stop
end subroutine MPI_Get_count

subroutine MPI_OP_Create(fn,l,a, ierr)
  integer a,ierr
  logical l
  external fn
end subroutine MPI_OP_Create