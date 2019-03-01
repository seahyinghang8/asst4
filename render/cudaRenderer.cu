#include <string>
#include <algorithm>
#include <math.h>
#include <stdio.h>
#include <vector>

#include <cuda.h>
#include <cuda_runtime.h>
#include <driver_functions.h>

#include "cudaRenderer.h"
#include "image.h"
#include "noise.h"
#include "sceneLoader.h"
#include "util.h"

#define BLOCKDIM 32
#define BLOCKSIZE (BLOCKDIM * BLOCKDIM)
#define SCAN_BLOCK_DIM BLOCKSIZE

#include "circleBoxTest.cu_inl"
#include "exclusiveScan.cu_inl"

////////////////////////////////////////////////////////////////////////////////////////
// Putting all the cuda kernels here
///////////////////////////////////////////////////////////////////////////////////////

struct GlobalConstants {

    SceneName sceneName;

    int numCircles;
    float* position;
    float* velocity;
    float* color;
    float* radius;

    int imageWidth;
    int imageHeight;
    float* imageData;
};

// Global variable that is in scope, but read-only, for all cuda
// kernels.  The __constant__ modifier designates this variable will
// be stored in special "constant" memory on the GPU. (we didn't talk
// about this type of memory in class, but constant memory is a fast
// place to put read-only variables).
__constant__ GlobalConstants cuConstRendererParams;

// read-only lookup tables used to quickly compute noise (needed by
// advanceAnimation for the snowflake scene)
__constant__ int    cuConstNoiseYPermutationTable[256];
__constant__ int    cuConstNoiseXPermutationTable[256];
__constant__ float  cuConstNoise1DValueTable[256];

// color ramp table needed for the color ramp lookup shader
#define COLOR_MAP_SIZE 5
__constant__ float  cuConstColorRamp[COLOR_MAP_SIZE][3];


// including parts of the CUDA code from external files to keep this
// file simpler and to seperate code that should not be modified
#include "noiseCuda.cu_inl"
#include "lookupColor.cu_inl"

__inline__ __device__ void
sharedMemInclusiveScan(int threadIndex, uint* sInput, uint* sOutput, volatile uint* sScratch, uint size)
{
    if (size > WARP_SIZE) {

        uint idata = sInput[threadIndex];

        //Bottom-level inclusive warp scan
        uint warpResult = warpScanInclusive(threadIndex, idata, sScratch, WARP_SIZE);

        // Save top elements of each warp for exclusive warp scan sync
        // to wait for warp scans to complete (because s_Data is being
        // overwritten)
        __syncthreads();

        if ( (threadIndex & (WARP_SIZE - 1)) == (WARP_SIZE - 1) )
            sScratch[threadIndex >> LOG2_WARP_SIZE] = warpResult;

        // wait for warp scans to complete
        __syncthreads();

        if ( threadIndex < (SCAN_BLOCK_DIM / WARP_SIZE)) {
            // grab top warp elements
            uint val = sScratch[threadIndex];
            // calculate exclusive scan and write back to shared memory
            sScratch[threadIndex] = warpScanExclusive(threadIndex, val, sScratch, size >> LOG2_WARP_SIZE);
        }

        //return updated warp scans with exclusive scan results
        __syncthreads();

        sOutput[threadIndex] = warpResult + sScratch[threadIndex >> LOG2_WARP_SIZE];

    } else if (threadIndex < WARP_SIZE) {
        uint idata = sInput[threadIndex];
        sOutput[threadIndex] = warpScanInclusive(threadIndex, idata, sScratch, size);
    }
}

// kernelClearImageSnowflake -- (CUDA device code)
//
// Clear the image, setting the image to the white-gray gradation that
// is used in the snowflake image
__global__ void kernelClearImageSnowflake() {

    int imageX = blockIdx.x * blockDim.x + threadIdx.x;
    int imageY = blockIdx.y * blockDim.y + threadIdx.y;

    int width = cuConstRendererParams.imageWidth;
    int height = cuConstRendererParams.imageHeight;

    if (imageX >= width || imageY >= height)
        return;

    int offset = 4 * (imageY * width + imageX);
    float shade = .4f + .45f * static_cast<float>(height-imageY) / height;
    float4 value = make_float4(shade, shade, shade, 1.f);

    // write to global memory: As an optimization, I use a float4
    // store, that results in more efficient code than if I coded this
    // up as four seperate fp32 stores.
    *(float4*)(&cuConstRendererParams.imageData[offset]) = value;
}

// kernelClearImage --  (CUDA device code)
//
// Clear the image, setting all pixels to the specified color rgba
__global__ void kernelClearImage(float r, float g, float b, float a) {

    int imageX = blockIdx.x * blockDim.x + threadIdx.x;
    int imageY = blockIdx.y * blockDim.y + threadIdx.y;

    int width = cuConstRendererParams.imageWidth;
    int height = cuConstRendererParams.imageHeight;

    if (imageX >= width || imageY >= height)
        return;

    int offset = 4 * (imageY * width + imageX);
    float4 value = make_float4(r, g, b, a);

    // write to global memory: As an optimization, I use a float4
    // store, that results in more efficient code than if I coded this
    // up as four seperate fp32 stores.
    *(float4*)(&cuConstRendererParams.imageData[offset]) = value;
}

// kernelAdvanceFireWorks
// 
// Update the position of the fireworks (if circle is firework)
__global__ void kernelAdvanceFireWorks() {
    const float dt = 1.f / 60.f;
    const float pi = 3.14159;
    const float maxDist = 0.25f;

    float* velocity = cuConstRendererParams.velocity;
    float* position = cuConstRendererParams.position;
    float* radius = cuConstRendererParams.radius;

    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index >= cuConstRendererParams.numCircles)
        return;

    if (0 <= index && index < NUM_FIREWORKS) { // firework center; no update 
        return;
    }

    // determine the fire-work center/spark indices
    int fIdx = (index - NUM_FIREWORKS) / NUM_SPARKS;
    int sfIdx = (index - NUM_FIREWORKS) % NUM_SPARKS;

    int index3i = 3 * fIdx;
    int sIdx = NUM_FIREWORKS + fIdx * NUM_SPARKS + sfIdx;
    int index3j = 3 * sIdx;

    float cx = position[index3i];
    float cy = position[index3i+1];

    // update position
    position[index3j] += velocity[index3j] * dt;
    position[index3j+1] += velocity[index3j+1] * dt;

    // fire-work sparks
    float sx = position[index3j];
    float sy = position[index3j+1];

    // compute vector from firework-spark
    float cxsx = sx - cx;
    float cysy = sy - cy;

    // compute distance from fire-work 
    float dist = sqrt(cxsx * cxsx + cysy * cysy);
    if (dist > maxDist) { // restore to starting position 
        // random starting position on fire-work's rim
        float angle = (sfIdx * 2 * pi)/NUM_SPARKS;
        float sinA = sin(angle);
        float cosA = cos(angle);
        float x = cosA * radius[fIdx];
        float y = sinA * radius[fIdx];

        position[index3j] = position[index3i] + x;
        position[index3j+1] = position[index3i+1] + y;
        position[index3j+2] = 0.0f;

        // travel scaled unit length 
        velocity[index3j] = cosA/5.0;
        velocity[index3j+1] = sinA/5.0;
        velocity[index3j+2] = 0.0f;
    }
}

// kernelAdvanceHypnosis   
//
// Update the radius/color of the circles
__global__ void kernelAdvanceHypnosis() { 
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index >= cuConstRendererParams.numCircles) 
        return; 

    float* radius = cuConstRendererParams.radius; 

    float cutOff = 0.5f;
    // place circle back in center after reaching threshold radisus 
    if (radius[index] > cutOff) { 
        radius[index] = 0.02f; 
    } else { 
        radius[index] += 0.01f; 
    }   
}   


// kernelAdvanceBouncingBalls
// 
// Update the position of the balls
__global__ void kernelAdvanceBouncingBalls() { 
    const float dt = 1.f / 60.f;
    const float kGravity = -2.8f; // sorry Newton
    const float kDragCoeff = -0.8f;
    const float epsilon = 0.001f;

    int index = blockIdx.x * blockDim.x + threadIdx.x; 
   
    if (index >= cuConstRendererParams.numCircles) 
        return; 

    float* velocity = cuConstRendererParams.velocity; 
    float* position = cuConstRendererParams.position; 

    int index3 = 3 * index;
    // reverse velocity if center position < 0
    float oldVelocity = velocity[index3+1];
    float oldPosition = position[index3+1];

    if (oldVelocity == 0.f && oldPosition == 0.f) { // stop-condition 
        return;
    }

    if (position[index3+1] < 0 && oldVelocity < 0.f) { // bounce ball 
        velocity[index3+1] *= kDragCoeff;
    }

    // update velocity: v = u + at (only along y-axis)
    velocity[index3+1] += kGravity * dt;

    // update positions (only along y-axis)
    position[index3+1] += velocity[index3+1] * dt;

    if (fabsf(velocity[index3+1] - oldVelocity) < epsilon
        && oldPosition < 0.0f
        && fabsf(position[index3+1]-oldPosition) < epsilon) { // stop ball 
        velocity[index3+1] = 0.f;
        position[index3+1] = 0.f;
    }
}

// kernelAdvanceSnowflake -- (CUDA device code)
//
// move the snowflake animation forward one time step.  Updates circle
// positions and velocities.  Note how the position of the snowflake
// is reset if it moves off the left, right, or bottom of the screen.
__global__ void kernelAdvanceSnowflake() {

    int index = blockIdx.x * blockDim.x + threadIdx.x;

    if (index >= cuConstRendererParams.numCircles)
        return;

    const float dt = 1.f / 60.f;
    const float kGravity = -1.8f; // sorry Newton
    const float kDragCoeff = 2.f;

    int index3 = 3 * index;

    float* positionPtr = &cuConstRendererParams.position[index3];
    float* velocityPtr = &cuConstRendererParams.velocity[index3];

    // loads from global memory
    float3 position = *((float3*)positionPtr);
    float3 velocity = *((float3*)velocityPtr);

    // hack to make farther circles move more slowly, giving the
    // illusion of parallax
    float forceScaling = fmin(fmax(1.f - position.z, .1f), 1.f); // clamp

    // add some noise to the motion to make the snow flutter
    float3 noiseInput;
    noiseInput.x = 10.f * position.x;
    noiseInput.y = 10.f * position.y;
    noiseInput.z = 255.f * position.z;
    float2 noiseForce = cudaVec2CellNoise(noiseInput, index);
    noiseForce.x *= 7.5f;
    noiseForce.y *= 5.f;

    // drag
    float2 dragForce;
    dragForce.x = -1.f * kDragCoeff * velocity.x;
    dragForce.y = -1.f * kDragCoeff * velocity.y;

    // update positions
    position.x += velocity.x * dt;
    position.y += velocity.y * dt;

    // update velocities
    velocity.x += forceScaling * (noiseForce.x + dragForce.y) * dt;
    velocity.y += forceScaling * (kGravity + noiseForce.y + dragForce.y) * dt;

    float radius = cuConstRendererParams.radius[index];

    // if the snowflake has moved off the left, right or bottom of
    // the screen, place it back at the top and give it a
    // pseudorandom x position and velocity.
    if ( (position.y + radius < 0.f) ||
         (position.x + radius) < -0.f ||
         (position.x - radius) > 1.f)
    {
        noiseInput.x = 255.f * position.x;
        noiseInput.y = 255.f * position.y;
        noiseInput.z = 255.f * position.z;
        noiseForce = cudaVec2CellNoise(noiseInput, index);

        position.x = .5f + .5f * noiseForce.x;
        position.y = 1.35f + radius;

        // restart from 0 vertical velocity.  Choose a
        // pseudo-random horizontal velocity.
        velocity.x = 2.f * noiseForce.y;
        velocity.y = 0.f;
    }

    // store updated positions and velocities to global memory
    *((float3*)positionPtr) = position;
    *((float3*)velocityPtr) = velocity;
}

// shadePixel -- (CUDA device code)
//
// given a pixel and a circle, determines the contribution to the
// pixel from the circle.  Update of the image is done in this
// function.  Called by kernelRenderCircles()
__device__ __inline__ void
shadePixel(int circleIndex, float2 pixelCenter, float3 p, float4* imagePtr) {

    float diffX = p.x - pixelCenter.x;
    float diffY = p.y - pixelCenter.y;
    float pixelDist = diffX * diffX + diffY * diffY;

    float rad = cuConstRendererParams.radius[circleIndex];;
    float maxDist = rad * rad;

    // circle does not contribute to the image
    if (pixelDist > maxDist)
        return;

    float3 rgb;
    float alpha;

    // there is a non-zero contribution.  Now compute the shading value

    // suggestion: This conditional is in the inner loop.  Although it
    // will evaluate the same for all threads, there is overhead in
    // setting up the lane masks etc to implement the conditional.  It
    // would be wise to perform this logic outside of the loop next in
    // kernelRenderCircles.  (If feeling good about yourself, you
    // could use some specialized template magic).
    if (cuConstRendererParams.sceneName == SNOWFLAKES || cuConstRendererParams.sceneName == SNOWFLAKES_SINGLE_FRAME) {

        const float kCircleMaxAlpha = .5f;
        const float falloffScale = 4.f;

        float normPixelDist = sqrt(pixelDist) / rad;
        rgb = lookupColor(normPixelDist);

        float maxAlpha = .6f + .4f * (1.f-p.z);
        maxAlpha = kCircleMaxAlpha * fmaxf(fminf(maxAlpha, 1.f), 0.f); // kCircleMaxAlpha * clamped value
        alpha = maxAlpha * exp(-1.f * falloffScale * normPixelDist * normPixelDist);

    } else {
        // simple: each circle has an assigned color
        int index3 = 3 * circleIndex;
        rgb = *(float3*)&(cuConstRendererParams.color[index3]);
        alpha = .5f;
    }

    float oneMinusAlpha = 1.f - alpha;

    // BEGIN SHOULD-BE-ATOMIC REGION
    // global memory read

    float4 existingColor = *imagePtr;
    float4 newColor;
    newColor.x = alpha * rgb.x + oneMinusAlpha * existingColor.x;
    newColor.y = alpha * rgb.y + oneMinusAlpha * existingColor.y;
    newColor.z = alpha * rgb.z + oneMinusAlpha * existingColor.z;
    newColor.w = alpha + existingColor.w;

    // global memory write
    *imagePtr = newColor;

    // END SHOULD-BE-ATOMIC REGION
}

// kernelRenderCircles -- (CUDA device code)
//
// Each thread renders a circle.  Since there is no protection to
// ensure order of update or mutual exclusion on the output image, the
// resulting image will be incorrect.
__global__ void kernelRenderCircles() {

    int index = blockIdx.x * blockDim.x + threadIdx.x;

    if (index >= cuConstRendererParams.numCircles)
        return;

    int index3 = 3 * index;

    // read position and radius
    float3 p = *(float3*)(&cuConstRendererParams.position[index3]);
    float  rad = cuConstRendererParams.radius[index];

    // compute the bounding box of the circle. The bound is in integer
    // screen coordinates, so it's clamped to the edges of the screen.
    short imageWidth = cuConstRendererParams.imageWidth;
    short imageHeight = cuConstRendererParams.imageHeight;
    short minX = static_cast<short>(imageWidth * (p.x - rad));
    short maxX = static_cast<short>(imageWidth * (p.x + rad)) + 1;
    short minY = static_cast<short>(imageHeight * (p.y - rad));
    short maxY = static_cast<short>(imageHeight * (p.y + rad)) + 1;

    // a bunch of clamps.  Is there a CUDA built-in for this?
    short screenMinX = (minX > 0) ? ((minX < imageWidth) ? minX : imageWidth) : 0;
    short screenMaxX = (maxX > 0) ? ((maxX < imageWidth) ? maxX : imageWidth) : 0;
    short screenMinY = (minY > 0) ? ((minY < imageHeight) ? minY : imageHeight) : 0;
    short screenMaxY = (maxY > 0) ? ((maxY < imageHeight) ? maxY : imageHeight) : 0;

    float invWidth = 1.f / imageWidth;
    float invHeight = 1.f / imageHeight;

    // for all pixels in the bonding box
    for (int pixelY=screenMinY; pixelY<screenMaxY; pixelY++) {
        float4* imgPtr = (float4*)(&cuConstRendererParams.imageData[4 * (pixelY * imageWidth + screenMinX)]);
        for (int pixelX=screenMinX; pixelX<screenMaxX; pixelX++) {
            float2 pixelCenterNorm = make_float2(invWidth * (static_cast<float>(pixelX) + 0.5f),
                                                 invHeight * (static_cast<float>(pixelY) + 0.5f));
            shadePixel(index, pixelCenterNorm, p, imgPtr);
            imgPtr++;
        }
    }
}

__inline__ __device__ void
checkConservativeCircles(float boxL, float boxR, float boxB, float boxT, size_t circleIdx, size_t tIdx, size_t numCircles, uint* inSection) {
    // Get the position and radius of the circle

    if (circleIdx >= numCircles) {
        inSection[tIdx] = 0;
    } else {
        float3 p = *(float3*)(&cuConstRendererParams.position[circleIdx * 3]);
        float rad = cuConstRendererParams.radius[circleIdx];

        inSection[tIdx] = static_cast<uint> (circleInBoxConservative(p.x, p.y, rad, boxL, boxR, boxT, boxB));
    }
}

__inline__ __device__ void
findConservativeCircles(size_t tIdx, size_t circleIdx, uint* inclusiveOutput, uint* probableCircles) {
    if (tIdx == 0) {
        if (inclusiveOutput[0] == 1) 
            probableCircles[0] = circleIdx;
    } else if (inclusiveOutput[tIdx] == (inclusiveOutput[tIdx-1]+1)) {
        probableCircles[inclusiveOutput[tIdx-1]] = circleIdx;
    }
}

__inline__ __device__ void
checkDefiniteCircles(float boxL, float boxR, float boxB, float boxT,
                     uint circleIdx, size_t tIdx, uint* inSection) {

    float3 p = *(float3*)(&cuConstRendererParams.position[circleIdx * 3]);
    float rad = cuConstRendererParams.radius[circleIdx];
    inSection[tIdx] = static_cast<uint> (circleInBox(p.x, p.y, rad, boxL, boxR, boxT, boxB));
}

__inline__ __device__ void
findDefiniteCircles(size_t tIdx, uint* inclusiveOutput, uint* definiteCircles, uint* probableCircles) {
    if (tIdx == 0) {
        if (inclusiveOutput[0] == 1) 
            definiteCircles[0] = probableCircles[0];
    } else if (inclusiveOutput[tIdx] == (inclusiveOutput[tIdx-1]+1)) {
        definiteCircles[inclusiveOutput[tIdx-1]] = probableCircles[tIdx];
    }
}

__inline__ __device__ void
myShadePixel(size_t circleIdx, float2 pixelCenterNorm, float4* imgPtr) {
    float3 p = *(float3*)(&cuConstRendererParams.position[circleIdx * 3]);
    shadePixel(circleIdx, pixelCenterNorm, p, imgPtr);
}


// myKernelRenderCircles (Ying Hang's parallel and correct version) -- (CUDA device code)
//
// Each thread renders a single pixel of the entire image
// A thread block will perform computation 

__global__ void myKernelRenderCircles() {

    // Get constant values
    short imageWidth = cuConstRendererParams.imageWidth;
    short imageHeight = cuConstRendererParams.imageHeight;
    float invWidth = 1.f / imageWidth;
    float invHeight = 1.f / imageHeight;

    // Compute some values about each thread
    size_t tIdx = blockDim.x * threadIdx.y + threadIdx.x;

    // Get the left, right, top and bottom of the section
    float boxL = static_cast<float>(blockIdx.x) / gridDim.x;
    float boxR = boxL + static_cast<float>(blockDim.x) / imageWidth;
    float boxB = static_cast<float>(blockIdx.y) / gridDim.y;
    float boxT = boxB + static_cast<float>(blockDim.y) / imageHeight;

    __shared__ uint inSection[BLOCKSIZE];
    __shared__ uint inclusiveOutput[BLOCKSIZE];
    __shared__ uint probableCircles[BLOCKSIZE];
    __shared__ uint scratchPad[2*BLOCKSIZE];
    
    // Set each thread to take on a pixel
    int pixelX = blockIdx.x * blockDim.x + threadIdx.x;
    int pixelY = blockIdx.y * blockDim.y + threadIdx.y;
    float4* imgPtr;
    float4 color;
    float2 pixelCenterNorm;

    if (pixelX < imageWidth && pixelY < imageHeight) {
        imgPtr = (float4*) &cuConstRendererParams.imageData[4 * 
                                (pixelY * imageWidth + pixelX)];

        color = *imgPtr;
        pixelCenterNorm = make_float2(invWidth * (static_cast<float>(pixelX) + 0.5f),
                                      invHeight * (static_cast<float>(pixelY) + 0.5f));
    }

    // Set constants to look at a certain number of circles per iteration
    const size_t numCirclesPerIteration = BLOCKSIZE;
    const size_t numCircles = cuConstRendererParams.numCircles;
    
    // if (numCircles < 32) {
    //     // check if pixel is within image
    //     if (pixelX < imageWidth && pixelY < imageHeight) {

    //         //loop definite circles
    //         for (size_t i=0; i < numCircles; i++) {
    //             myShadePixel(i, pixelCenterNorm, &color);
    //         }
    //     }
    // } else {

        // ensure all the threads reach the start of the loop at the same time
        for (size_t circleIdxStart = 0;
                circleIdxStart < numCircles;
                circleIdxStart += numCirclesPerIteration) {

            // first figure out all the circles that are inside the section
            // all the threads will work together in parallel

            size_t circleIdx = tIdx + circleIdxStart;

            checkConservativeCircles(boxL, boxR, boxB, boxT, circleIdx, tIdx, numCircles, inSection);
            __syncthreads();
            sharedMemInclusiveScan(tIdx, inSection, inclusiveOutput, scratchPad, BLOCKSIZE);
            __syncthreads();
            findConservativeCircles(tIdx, circleIdx, inclusiveOutput, probableCircles);
            size_t numConservativeCircles = inclusiveOutput[BLOCKSIZE-1];

            __syncthreads();

            // check definitive circles
            if (tIdx >= numConservativeCircles) {
                inSection[tIdx] = 0;
            } else {
                checkDefiniteCircles(boxL, boxR, boxB, boxT, probableCircles[tIdx], tIdx, inSection);
            }
            __syncthreads();
            sharedMemInclusiveScan(tIdx, inSection, inclusiveOutput, scratchPad, BLOCKSIZE);
            __syncthreads();
/*****************************************************************************/
/**                         RENAMING ARRAY!!!!!                             **/
/*****************************************************************************/
            uint* definiteCircles = inSection;
            findDefiniteCircles(tIdx, inclusiveOutput, definiteCircles, probableCircles);
            size_t numDefiniteCircles = inclusiveOutput[numConservativeCircles-1];
            __syncthreads();

            // now that the thread block has figured out which circles are inside the section
            // now each thread represents a pixel

            // check if pixel is within image
            if (pixelX < imageWidth && pixelY < imageHeight) {

                //loop definite circles
                for (size_t i=0; i < numDefiniteCircles; i++) {

                    size_t circleIdx = definiteCircles[i];
                    myShadePixel(circleIdx, pixelCenterNorm, &color);
                }
            }
            __syncthreads();
        }
    // }
    if (pixelX < imageWidth && pixelY < imageHeight) {
        *imgPtr = color;
    }

}


// mySmallKernelRenderCircles (Ying Hang's parallel and correct version) -- (CUDA device code)
//
// Each thread renders a single pixel of the entire image
// A thread block will perform computation 

__global__ void mySmallKernelRenderCircles() {

    // Get constant values
    short imageWidth = cuConstRendererParams.imageWidth;
    short imageHeight = cuConstRendererParams.imageHeight;
    float invWidth = 1.f / imageWidth;
    float invHeight = 1.f / imageHeight;
    
    // Set each thread to take on a pixel
    int pixelX = blockIdx.x * blockDim.x + threadIdx.x;
    int pixelY = blockIdx.y * blockDim.y + threadIdx.y;
    float4* imgPtr;
    float4 color;
    float2 pixelCenterNorm;

    if (pixelX < imageWidth && pixelY < imageHeight) {
        imgPtr = (float4*) &cuConstRendererParams.imageData[4 * 
                                (pixelY * imageWidth + pixelX)];

        color = *imgPtr;
        pixelCenterNorm = make_float2(invWidth * (static_cast<float>(pixelX) + 0.5f),
                                      invHeight * (static_cast<float>(pixelY) + 0.5f));
    }

    const size_t numCircles = cuConstRendererParams.numCircles;
    
    // check if pixel is within image
    if (pixelX < imageWidth && pixelY < imageHeight) {

        //loop circles
        for (size_t i=0; i < numCircles; i++) {
            myShadePixel(i, pixelCenterNorm, &color);
        }
    }
    if (pixelX < imageWidth && pixelY < imageHeight) {
        *imgPtr = color;
    }

}
////////////////////////////////////////////////////////////////////////////////////////


CudaRenderer::CudaRenderer() {
    image = NULL;

    numCircles = 0;
    position = NULL;
    velocity = NULL;
    color = NULL;
    radius = NULL;

    cudaDevicePosition = NULL;
    cudaDeviceVelocity = NULL;
    cudaDeviceColor = NULL;
    cudaDeviceRadius = NULL;
    cudaDeviceImageData = NULL;
}

CudaRenderer::~CudaRenderer() {

    if (image) {
        delete image;
    }

    if (position) {
        delete [] position;
        delete [] velocity;
        delete [] color;
        delete [] radius;
    }

    if (cudaDevicePosition) {
        cudaFree(cudaDevicePosition);
        cudaFree(cudaDeviceVelocity);
        cudaFree(cudaDeviceColor);
        cudaFree(cudaDeviceRadius);
        cudaFree(cudaDeviceImageData);
    }
}

const Image*
CudaRenderer::getImage() {

    // need to copy contents of the rendered image from device memory
    // before we expose the Image object to the caller

    printf("Copying image data from device\n");

    cudaMemcpy(image->data,
            cudaDeviceImageData,
            sizeof(float) * 4 * image->width * image->height,
            cudaMemcpyDeviceToHost);

    return image;
}

void
CudaRenderer::loadScene(SceneName scene) {
    sceneName = scene;
    loadCircleScene(sceneName, numCircles, position, velocity, color, radius);
}

void
CudaRenderer::setup() {

    int deviceCount = 0;
    std::string name;
    cudaError_t err = cudaGetDeviceCount(&deviceCount);

    printf("---------------------------------------------------------\n");
    printf("Initializing CUDA for CudaRenderer\n");
    printf("Found %d CUDA devices\n", deviceCount);

    for (int i=0; i<deviceCount; i++) {
        cudaDeviceProp deviceProps;
        cudaGetDeviceProperties(&deviceProps, i);
        name = deviceProps.name;

        printf("Device %d: %s\n", i, deviceProps.name);
        printf("   SMs:        %d\n", deviceProps.multiProcessorCount);
        printf("   Global mem: %.0f MB\n", static_cast<float>(deviceProps.totalGlobalMem) / (1024 * 1024));
        printf("   CUDA Cap:   %d.%d\n", deviceProps.major, deviceProps.minor);
    }
    printf("---------------------------------------------------------\n");
    
    // By this time the scene should be loaded.  Now copy all the key
    // data structures into device memory so they are accessible to
    // CUDA kernels
    //
    // See the CUDA Programmer's Guide for descriptions of
    // cudaMalloc and cudaMemcpy

    cudaMalloc(&cudaDevicePosition, sizeof(float) * 3 * numCircles);
    cudaMalloc(&cudaDeviceVelocity, sizeof(float) * 3 * numCircles);
    cudaMalloc(&cudaDeviceColor, sizeof(float) * 3 * numCircles);
    cudaMalloc(&cudaDeviceRadius, sizeof(float) * numCircles);
    cudaMalloc(&cudaDeviceImageData, sizeof(float) * 4 * image->width * image->height);

    cudaMemcpy(cudaDevicePosition, position, sizeof(float) * 3 * numCircles, cudaMemcpyHostToDevice);
    cudaMemcpy(cudaDeviceVelocity, velocity, sizeof(float) * 3 * numCircles, cudaMemcpyHostToDevice);
    cudaMemcpy(cudaDeviceColor, color, sizeof(float) * 3 * numCircles, cudaMemcpyHostToDevice);
    cudaMemcpy(cudaDeviceRadius, radius, sizeof(float) * numCircles, cudaMemcpyHostToDevice);

    // Initialize parameters in constant memory.  We didn't talk about
    // constant memory in class, but the use of read-only constant
    // memory here is an optimization over just sticking these values
    // in device global memory.  NVIDIA GPUs have a few special tricks
    // for optimizing access to constant memory.  Using global memory
    // here would have worked just as well.  See the Programmer's
    // Guide for more information about constant memory.

    GlobalConstants params;
    params.sceneName = sceneName;
    params.numCircles = numCircles;
    params.imageWidth = image->width;
    params.imageHeight = image->height;
    params.position = cudaDevicePosition;
    params.velocity = cudaDeviceVelocity;
    params.color = cudaDeviceColor;
    params.radius = cudaDeviceRadius;
    params.imageData = cudaDeviceImageData;

    cudaMemcpyToSymbol(cuConstRendererParams, &params, sizeof(GlobalConstants));

    // also need to copy over the noise lookup tables, so we can
    // implement noise on the GPU
    int* permX;
    int* permY;
    float* value1D;
    getNoiseTables(&permX, &permY, &value1D);
    cudaMemcpyToSymbol(cuConstNoiseXPermutationTable, permX, sizeof(int) * 256);
    cudaMemcpyToSymbol(cuConstNoiseYPermutationTable, permY, sizeof(int) * 256);
    cudaMemcpyToSymbol(cuConstNoise1DValueTable, value1D, sizeof(float) * 256);

    // last, copy over the color table that's used by the shading
    // function for circles in the snowflake demo

    float lookupTable[COLOR_MAP_SIZE][3] = {
        {1.f, 1.f, 1.f},
        {1.f, 1.f, 1.f},
        {.8f, .9f, 1.f},
        {.8f, .9f, 1.f},
        {.8f, 0.8f, 1.f},
    };

    cudaMemcpyToSymbol(cuConstColorRamp, lookupTable, sizeof(float) * 3 * COLOR_MAP_SIZE);

}

// allocOutputImage --
//
// Allocate buffer the renderer will render into.  Check status of
// image first to avoid memory leak.
void
CudaRenderer::allocOutputImage(int width, int height) {

    if (image)
        delete image;
    image = new Image(width, height);
}

// clearImage --
//
// Clear's the renderer's target image.  The state of the image after
// the clear depends on the scene being rendered.
void
CudaRenderer::clearImage() {

    // 256 threads per block is a healthy number
    dim3 blockDim(16, 16, 1);
    dim3 gridDim(
        (image->width + blockDim.x - 1) / blockDim.x,
        (image->height + blockDim.y - 1) / blockDim.y);

    if (sceneName == SNOWFLAKES || sceneName == SNOWFLAKES_SINGLE_FRAME) {
        kernelClearImageSnowflake<<<gridDim, blockDim>>>();
    } else {
        kernelClearImage<<<gridDim, blockDim>>>(1.f, 1.f, 1.f, 1.f);
    }
    cudaDeviceSynchronize();
}

// advanceAnimation --
//
// Advance the simulation one time step.  Updates all circle positions
// and velocities
void
CudaRenderer::advanceAnimation() {
     // 256 threads per block is a healthy number
    dim3 blockDim(256, 1);
    dim3 gridDim((numCircles + blockDim.x - 1) / blockDim.x);

    // only the snowflake scene has animation
    if (sceneName == SNOWFLAKES) {
        kernelAdvanceSnowflake<<<gridDim, blockDim>>>();
    } else if (sceneName == BOUNCING_BALLS) {
        kernelAdvanceBouncingBalls<<<gridDim, blockDim>>>();
    } else if (sceneName == HYPNOSIS) {
        kernelAdvanceHypnosis<<<gridDim, blockDim>>>();
    } else if (sceneName == FIREWORKS) { 
        kernelAdvanceFireWorks<<<gridDim, blockDim>>>(); 
    }
    cudaDeviceSynchronize();
}

// Each kernel call renders a circle
__global__ void kernelRenderOneCircle(
    float screenMinX,
    float screenMaxX,
    float screenMinY,
    float screenMaxY,
    float invHeight,
    float invWidth,
    int circleIdx) {

    int tIdx = blockIdx.x * blockDim.x + threadIdx.x;
    int totalPixelsNeeded = (screenMaxX - screenMinX) * (screenMaxY - screenMinY);
    if (tIdx > totalPixelsNeeded) return;

    // x_dimensions
    int xDim = screenMaxX - screenMinX;
    // calculate pixel x and pixel y
    int pixelX = tIdx % xDim + screenMinX;
    int pixelY = tIdx / xDim + screenMinY;
    short imageWidth = cuConstRendererParams.imageWidth;

    float3 p = *(float3*)(&cuConstRendererParams.position[circleIdx * 3]);
    float4* imgPtr = (float4*)(&cuConstRendererParams.imageData[4 * (pixelY * imageWidth + pixelX)]);
    // for all pixels in the bonding box
    float2 pixelCenterNorm = make_float2(invWidth * (static_cast<float>(pixelX) + 0.5f),
                                         invHeight * (static_cast<float>(pixelY) + 0.5f));
    shadePixel(circleIdx, pixelCenterNorm, p, imgPtr);
}

void
CudaRenderer::render() {

    // 256 threads per block is a healthy number
    // dim3 blockDim(256, 1);
    // dim3 gridDim((numCircles + blockDim.x - 1) / blockDim.x);

    // kernelRenderCircles<<<gridDim, blockDim>>>();

    // NOTE: Ying Hang's Modified Version
    // 32 * 32 = 1024 threads per block is a healthy number
    // each block handles a 32x32 section of the image
    dim3 blockDim(BLOCKDIM, BLOCKDIM);
    // the whole image is divided into 32x32 sections
    size_t gridDimX = (image->width + blockDim.x - 1) / blockDim.x;
    size_t gridDimY = (image->height + blockDim.y - 1) / blockDim.y;
    dim3 gridDim(gridDimX, gridDimY);

    //printf("I have %d threads and I have %d pixels\n",gridDim.x * blockDim.x * gridDim.y * blockDim.y, image->width * image->height);

    if (numCircles >= 4) { //dubious ???
        myKernelRenderCircles<<<gridDim, blockDim>>>();
    } else {
        short imageWidth = image->width;
        short imageHeight = image->height;
        float invWidth = 1.f / imageWidth;
        float invHeight = 1.f / imageHeight;

        for (int i = 0; i < numCircles; i++) {
            // read position and radius
            float px = position[i * 3];
            float py = position[i * 3 +1];
            float rad = radius[i];

            // compute the bounding box of the circle.  This bounding box
            // is in normalized coordinates

            short minX = static_cast<short>(imageWidth * (px - rad));
            short maxX = static_cast<short>(imageWidth * (px + rad)) + 1;
            short minY = static_cast<short>(imageHeight * (py - rad));
            short maxY = static_cast<short>(imageHeight * (py + rad)) + 1;

            // a bunch of clamps.  Is there a CUDA built-in for this?
            short screenMinX = (minX > 0) ? ((minX < imageWidth) ? minX : imageWidth) : 0;
            short screenMaxX = (maxX > 0) ? ((maxX < imageWidth) ? maxX : imageWidth) : 0;
            short screenMinY = (minY > 0) ? ((minY < imageHeight) ? minY : imageHeight) : 0;
            short screenMaxY = (maxY > 0) ? ((maxY < imageHeight) ? maxY : imageHeight) : 0;

            int totalPixelsNeeded = (screenMaxX - screenMinX) * (screenMaxY - screenMinY);
            const int THREADS_PER_BLOCK = 64;
            int num_blocks = (totalPixelsNeeded + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;

            kernelRenderOneCircle<<<num_blocks, THREADS_PER_BLOCK>>>(
                    screenMinX,
                    screenMaxX,
                    screenMinY,
                    screenMaxY,
                    invHeight,
                    invWidth,
                    i);
            cudaDeviceSynchronize();
        }
    }
    cudaDeviceSynchronize();

}

