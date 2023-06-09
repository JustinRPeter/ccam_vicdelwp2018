c $Log: esbda.f,v $
c Revision 1.1.1.1  2003/08/13 01:24:20  dix043
c Imported sources
c
c Revision 1.1  1996/10/17  05:14:15  mrd
c Initial revision
c
c Revision 1.3  1996/07/01  02:24:14  ldr
c Add comments showing temperatures for each row.
c
c Revision 1.2  1993/12/17  15:32:23  ldr
c Hack V4-4-52l to change all continuation chars to &
c
c Revision 1.1  91/02/22  16:37:18  ldr
c Initial release V3-0
c 
      block data esbda
C     MKS table
C     TABLE OF ES fROM -150 C TO +70 C IN ONE-DEGREE INCREMENTS.
C     Temperature of last ES in each row is shown as a comment.
C                                                                      ! TEMP
      real, dimension(0:220) :: table
      common /es_table/ table
      
      data (table(i),i=0,99) /1.e-9, 1.e-9, 2.e-9, 3.e-9, 4.e-9,       !-146C
     & 6.e-9, 9.e-9, 13.e-9, 18.e-9, 26.e-9,                           !-141C
     & 36.e-9, 51.e-9, 71.e-9, 99.e-9, 136.e-9,                        !-136C
     & 0.000000188, 0.000000258, 0.000000352, 0.000000479, 0.000000648,!-131C
     & 0.000000874, 0.000001173, 0.000001569, 0.000002090, 0.000002774,!-126C
     & 0.000003667, 0.000004831, 0.000006340, 0.000008292, 0.00001081, !-121C
     & 0.00001404, 0.00001817, 0.00002345, 0.00003016, 0.00003866,     !-116C
     & 0.00004942, 0.00006297, 0.00008001, 0.0001014, 0.0001280,       !-111C
     & 0.0001613, 0.0002026, 0.0002538, 0.0003170, 0.0003951,          !-106C
     & 0.0004910, 0.0006087, 0.0007528, 0.0009287, 0.001143,           !-101C
     & .001403, .001719, .002101, .002561, .003117, .003784,            !-95C
     & .004584, .005542, .006685, .008049, .009672,.01160,.01388,.01658,!-87C
     & .01977, .02353, .02796,.03316,.03925,.04638,.05472,.06444,.07577,!-78C
     & .08894, .1042, .1220, .1425, .1662, .1936, .2252, .2615, .3032,  !-69C
     & .3511, .4060, .4688, .5406, .6225, .7159, .8223, .9432, 1.080,   !-60C
     & 1.236, 1.413, 1.612, 1.838, 2.092, 2.380, 2.703, 3.067, 3.476/   !-51C

      data (table(i),i=100,220) /
     & 3.935,4.449, 5.026, 5.671, 6.393, 7.198, 8.097, 9.098,           !-43C
     & 10.21, 11.45, 12.83, 14.36, 16.06, 17.94, 20.02, 22.33, 24.88,   !-34C
     & 27.69, 30.79, 34.21, 37.98, 42.13, 46.69,51.70,57.20,63.23,69.85,!-24C 
     & 77.09, 85.02, 93.70, 103.20, 114.66, 127.20, 140.81, 155.67,     !-16C
     & 171.69, 189.03, 207.76, 227.96 , 249.67, 272.98, 298.00, 324.78, !-8C
     & 353.41, 383.98, 416.48, 451.05, 487.69, 526.51, 567.52, 610.78,  !0C
     & 656.62, 705.47, 757.53, 812.94, 871.92, 934.65, 1001.3, 1072.2,  !8C
     & 1147.4, 1227.2, 1311.9, 1401.7, 1496.9, 1597.7, 1704.4, 1817.3,  !16C
     & 1936.7, 2063.0, 2196.4, 2337.3, 2486.1, 2643.0, 2808.6, 2983.1,  !24C
     & 3167.1, 3360.8, 3564.9, 3779.6, 4005.5, 4243.0, 4492.7, 4755.1,  !32C
     & 5030.7, 5320.0, 5623.6, 5942.2, 6276.2, 6626.4, 6993.4, 7377.7,  !40C
     & 7780.2, 8201.5, 8642.3, 9103.4, 9585.5, 10089.0, 10616.0,        !47C
     & 11166.0, 11740.0, 12340.0, 12965.0, 13617.0, 14298.0, 15007.0,   !54C
     & 15746.0, 16516.0, 17318.0, 18153.0, 19022.0, 19926.0, 20867.0,   !61C
     t 21845.0, 22861.0, 23918.0, 25016.0, 26156.0, 27340.0, 28570.0,   !68C
     & 29845.0, 31169.0/                                                !70C

      end
