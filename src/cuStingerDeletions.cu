#include <thrust/device_vector.h>
#include <thrust/host_vector.h>

#include "main.hpp"

using namespace std;

__global__ void deviceEdgeDeletesSweep1(cuStinger* custing, BatchUpdateData* bud,int32_t updatesPerBlock){
	length_t* d_utilized      = custing->dVD->getUsed();
	length_t* d_max           = custing->dVD->getMax();
	cuStinger::cusEdgeData** d_adj = custing->dVD->getAdj();	
	vertexId_t* d_updatesSrc    = bud->getSrc();
	vertexId_t* d_updatesDst    = bud->getDst();
	length_t batchSize          = *(bud->getBatchSize());

	__shared__ int64_t found[1], research[1];

	int32_t init_pos = blockIdx.x * updatesPerBlock;
	// Updates are processed one at a time	
	for (int32_t i=0; i<updatesPerBlock; i++){
		int32_t pos=init_pos+i;
		if(pos>=batchSize)
			break;
		__syncthreads();

		vertexId_t src = d_updatesSrc[pos],dst = d_updatesDst[pos];
		if(threadIdx.x ==0){
			*found=-1;
		}
		__syncthreads();
		
		length_t srcInitSize = d_utilized[src];
		for(int iter=0; iter<10 && *found==-1; iter++){
			srcInitSize = max(srcInitSize,d_utilized[src]);

			// length_t srcInitSize = d_utilized[src];
			// Checking to see if the edge already exists in the graph. 
			for (length_t e=threadIdx.x; e<srcInitSize && *found==-1; e+=blockDim.x){
				if(d_adj[src]->dst[e]==dst){
					*found=e;
					break;
				}
			}
			__syncthreads();
	
			length_t last,dupLast;
			vertexId_t prevValCurr, prevValMove,lastVal;
			if(*found!=-1 && threadIdx.x==0){
				last =  atomicSub(d_utilized+src, 1)-1; // Recall that the utilized refers to the length, thus we need to subtract one to get the last element
				lastVal = d_adj[src]->dst[last];
				if (lastVal==DELETION_MARKER){
					*found=-1;
					// atomicAdd(d_utilized+src, 1);
				}
				else if(*found <last){
					if(last>0){
						// prevVal = atomicCAS(d_adj[src]->dst + *found,dst,lastVal);
						prevValMove = atomicCAS(d_adj[src]->dst + last,lastVal,DELETION_MARKER);
						if(prevValMove==DELETION_MARKER){// edge has already moved by another vertex
							*found=-1;
							atomicAdd(d_utilized+src, 1);
						}
						else{
							prevValCurr = atomicCAS(d_adj[src]->dst + *found,dst,prevValMove);
							if(prevValCurr==DELETION_MARKER){
								*found=-1;
								atomicCAS(d_adj[src]->dst + last,DELETION_MARKER,prevValMove);
								atomicAdd(d_utilized+src, 1);
							}
							else if(prevValCurr!=dst){// Duplicate edge in batch 
								atomicCAS(d_adj[src]->dst + last,DELETION_MARKER,prevValMove);
								atomicAdd(d_utilized+src, 1);
								// d_adj[src]->dst[dupLast] =lastVal;
								//printf("For the love of me\n");
							}
						}
					}
				}
				else if(last==0){
						dupLast =  atomicAdd(d_utilized+src, 1); // Recall that the utilized refers to the length, thus we need to subtract one to get the last element
						*found=-1;
						// printf("Possibly here\n");
				}else if (last<0){ // Trying to delete when an edge doesn't exist.	
						dupLast =  atomicAdd(d_utilized+src, 1); // Recall that the utilized refers to the length, thus we need to subtract one to get the last element
						*found=-1;
						// printf("Or Possibly here\n");
				}
			}
			__syncthreads();

#if 0
			// if(src ==26771 && dst ==30510 && threadIdx.x==0){
			if(iter ==9 && threadIdx.x==0){
				printf("\nI DID IT %d %d %d %d\n", src,dst, srcInitSize, d_utilized[src]);
				for(length_t e=0; e<srcInitSize; e++)
					printf("%d ,",d_adj[src]->dst[e]);
				printf("\n");
				for(length_t e=0; e<d_utilized[src]; e++)
					printf("%d ,",d_adj[src]->dst[e]);
				printf("\n");

				printf("\n");
			}
#endif

			__syncthreads();

		}

	}
}


void cuStinger::edgeDeletions(BatchUpdate &bu)
{	
	dim3 numBlocks(1, 1);
	int32_t threads=32;
	dim3 threadsPerBlock(threads, 1);
	int32_t updatesPerBlock,dupsPerBlock;
	length_t updateSize,dupInBatch;

	updateSize = *(bu.getHostBUD()->getBatchSize());
	numBlocks.x = ceil((float)updateSize/(float)threads);
	if (numBlocks.x>16000){
		numBlocks.x=16000;
	}	
	updatesPerBlock = ceil(float(updateSize)/float(numBlocks.x));

	deviceEdgeDeletesSweep1<<<numBlocks,threadsPerBlock>>>(this->devicePtr(), bu.getDeviceBUD()->devicePtr(),updatesPerBlock);
	checkLastCudaError("Error in the first delete sweep");

	bu.getHostBUD()->copyDeviceToHost(*bu.getDeviceBUD());
	reAllocateMemoryAfterSweep1(bu);

	bu.getHostBUD()->resetIncCount();
	bu.getDeviceBUD()->resetIncCount();
	bu.getHostBUD()->resetDuplicateCount();
	bu.getDeviceBUD()->resetDuplicateCount();
}


	
__global__ void deviceVerifyDeletions(cuStinger* custing, BatchUpdateData* bud,int32_t updatesPerBlock, length_t* updateCounter){
	length_t* d_utilized      = custing->dVD->getUsed();
	length_t* d_max           = custing->dVD->getMax();
	cuStinger::cusEdgeData** d_adj = custing->dVD->getAdj();	
	vertexId_t* d_updatesSrc    = bud->getSrc();
	vertexId_t* d_updatesDst    = bud->getDst();
	length_t batchSize          = *(bud->getBatchSize());
	length_t* d_incCount        = bud->getIncCount();
	vertexId_t* d_indIncomplete = bud->getIndIncomplete();
	length_t* d_indDuplicate    = bud->getIndDuplicate();
	length_t* d_dupCount        = bud->getDuplicateCount();
	length_t* d_dupRelPos       = bud->getDupPosBatch();

	__shared__ int32_t found[1];

	int32_t init_pos = blockIdx.x * updatesPerBlock;

	if (threadIdx.x==0)
		updateCounter[blockIdx.x]=0;
	__syncthreads();

	// Updates are processed one at a time	
	for (int32_t i=0; i<updatesPerBlock; i++){
		int32_t pos=init_pos+i;
		if(pos>=batchSize)
			break;

		vertexId_t src = d_updatesSrc[pos],dst = d_updatesDst[pos];
		length_t srcInitSize = d_utilized[src];
		if(threadIdx.x ==0)
			*found=0;
		__syncthreads();

		// Checking to see if the edge already exists in the graph. 
		for (length_t e=threadIdx.x; e<srcInitSize && *found==0; e+=blockDim.x){
			if(d_adj[src]->dst[e]==dst ){
				*found=1;
				printf("^^^^ Found it : %d %d\n",src,dst);
				break;
			}
		}
		__syncthreads();
	
		if (threadIdx.x==0)
			updateCounter[blockIdx.x]+=*found;
		__syncthreads();
	}
}

void cuStinger::verifyEdgeDeletions(BatchUpdate &bu){
	dim3 numBlocks(1, 1);
	int32_t threads=32;
	dim3 threadsPerBlock(threads, 1);
	int32_t updatesPerBlock,dupsPerBlock;
	length_t updateSize,dupInBatch;

	updateSize = *(bu.getHostBUD()->getBatchSize());
	numBlocks.x = ceil((float)updateSize/(float)threads);
	if (numBlocks.x>16000){
		numBlocks.x=16000;
	}	
	updatesPerBlock = ceil(float(updateSize)/float(numBlocks.x));

	length_t* devCounter = (length_t*)allocDeviceArray(numBlocks.x,sizeof(length_t));
	deviceVerifyDeletions<<<numBlocks,threadsPerBlock>>>(this->devicePtr(), bu.getDeviceBUD()->devicePtr(),updatesPerBlock,devCounter);
	length_t verified = cuStinger::sumDeviceArray(devCounter, numBlocks.x);

	if (verified==0)
		cout << "All deletions are accounted for.             Not deleted : " << verified << endl;
	else
		cout << "Some of the deletions are NOT accounted for. Not deleted : " << verified << endl;

	freeDeviceArray(devCounter);
}



