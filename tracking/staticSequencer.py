# coding: utf-8
import tracking.TrajectorySimulator
import PIL.Image
import PIL.ImageDraw
import cv2
import numpy
import pycocotools.coco
import matplotlib
import matplotlib.pyplot

if __name__ == '__main__':
    #Define paths
    dataDir='/home/datasets/datasets1/mscoco/'
    dataType='train2014'
    annFile='%s/annotations/instances_%s.json'%(dataDir,dataType)
    #Load dataset info/handler
    coco = pycocotools.coco.COCO(annFile)
    #Load categories and all images having those
    catIds = coco.getCatIds()
    cats = coco.loadCats()
    nms=[cat['name'] for cat in cats]
    imgIds = coco.getImgIds(catIds=catIds)
    print 'Number of categories {} and corresponding images {}'.format(len(catIds), len(imgIds))

    #Select and show an annotated image
    img = coco.loadImgs(imgIds[numpy.random.randint(0,len(imgIds))])[0]
    image = PIL.Image.open('%s/%s/%s'%(dataDir,dataType,img['file_name']))
    matplotlib.pyplot.imshow(numpy.asarray(image))
    #Load the annotations for the sampled image
    annIds = coco.getAnnIds(imgIds=img['id'], catIds=catIds, iscrowd=None)
    anns = coco.loadAnns(annIds)

    #Create sampler
    aSampler = tracking.TrajectorySimulator.AffineSampler()
    polygon = anns[1]['segmentation'][0]
    bounds = aSampler.polygonBounds(polygon)
    crop = aSampler.segmentCrop(image, polygon)

    for index in xrange(120):
        aSampler.sample()
        #print 'Current sampler parameters {}'.format(aSampler)
        transformed = aSampler.applyTransform(crop)
        pasted = aSampler.pasteCrop(image, tuple(bounds[:2]), transformed)
        #matplotlib.pyplot.imshow(numpy.asarray(pasted))
        cv2.imshow('sequence', numpy.asarray(pasted))
        cv2.waitKey(1)
