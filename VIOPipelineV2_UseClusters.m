function [T_wcam_estimated,T_wimu_estimated, T_wimu_gtsam, keyFrames] = VIOPipelineV2_UseClusters(K, T_camimu, monoImageData, rgbImageData, imuData, pipelineOptions, noiseParams, xInit, g_w, clusteringModel, clusterWeights)
%VIOPIPELINE Run the Visual Inertial Odometry Pipeline
% K: camera intrinsics
% T_camimu: transformation from the imu to the camera frame
% imuData: struct with IMU data:
%           imuData.timestamps: 1xN 
%           imuData.measAccel: 3xN
%           imuData.measOmega: 3xN
%           imuData.measOrient: 4xN (quaternion q_sw, with scalar in the
%           1st position. The world frame is defined as the N-E-Down ref.
%           frame.
% monoImageData:
%           monoImageData.timestamps: 1xM
%           monoImageData.rectImages: WxHxM
% params:
%           params.INIT_DISPARITY_THRESHOLD
%           params.KF_DISPARITY_THRESHOLD
%           params.MIN_FEATURE_MATCHES

% Import opencv
import cv.*;
import gtsam.*;


%===GTSAM INITIALIATION====%
currentPoseGlobal = Pose3(Rot3(rotmat_from_quat(xInit.q)), Point3(xInit.p)); % initial pose is the reference frame (navigation frame)
currentVelocityGlobal = LieVector(xInit.v); 
currentBias = imuBias.ConstantBias(noiseParams.init_ba, noiseParams.init_bg);
sigma_init_x = noiseModel.Isotropic.Sigmas([ 0.01; 0.01; 0.01; 0.01; 0.01; 0.01 ]);
sigma_init_v = noiseModel.Isotropic.Sigma(3, 0.0000001);
sigma_init_b = noiseModel.Isotropic.Sigmas([zeros(3,1); zeros(3,1) ]);
sigma_between_b = [ noiseParams.sigma_ba * ones(3,1); noiseParams.sigma_bg * ones(3,1) ];
w_coriolis = [0;0;0];
% Solver object
isamParams = ISAM2Params;
%isamParams.setRelinearizeSkip(20);
isamParams.setFactorization('CHOLESKY');
isamParams.setEnableDetailedResults(true);
isam = gtsam.ISAM2(isamParams);
newFactors = NonlinearFactorGraph;
newValues = Values;
%==========================%


invK = inv(K);
% Main loop
% Keep track of key frames and poses
referencePose = {};

%Key frame poses correspond to the first and second poses from which 
%point clouds are triangulated (these must have sufficient disparity)
keyFrames = [];
keyFrame_i = 1;
initiliazationComplete = false;




% Main loop
% ==========================================================
% Sort all measurements by their timestamps, process measurements as if in
% real-time

%All measurements are assigned a unique measurement ID based on their
%timestamp
numImageMeasurements = length(monoImageData.timestamps);
numImuMeasurements = length(imuData.timestamps);
numMeasurements = numImuMeasurements + numImageMeasurements;

allTimestamps = [monoImageData.timestamps imuData.timestamps];
[~,measIdsTimeSorted] = sort(allTimestamps); %Sort timestamps in ascending order
 

camMeasId = 0;
imuMeasId = 0;
firstImageProcessed = false;


%Initialize the state
xPrev = xInit;



%Initialize the history
R_wimu = rotmat_from_quat(xPrev.q);
R_imuw = R_wimu';
p_imuw_w = xPrev.p;
T_wimu_estimated = inv([R_imuw -R_imuw*p_imuw_w; 0 0 0 1]);
T_wcam_estimated = T_wimu_estimated*inv(T_camimu);
T_wimu_gtsam = [];


iter = 1;

%Keep track of landmarks
insertedLandmarkIds = [];
initializedLandmarkIds = [];
pastObservations.pixels = [];
pastObservations.poseKeys = [];
pastObservations.triangPoints = [];
pastObservations.ids =  [];
pastObservations.predVectors = [];


for measId = measIdsTimeSorted
    % Which type of measurement is this?
    if measId > numImageMeasurements
        measType = 'IMU';
        imuMeasId = measId - numImageMeasurements;
    else 
        measType = 'Cam';
        camMeasId = measId;
    end
    
    
    % IMU Measurement
    % ==========================================================
    if strcmp(measType, 'IMU')
        if pipelineOptions.verbose
            disp(['Processing IMU Measurement. ID: ' num2str(imuMeasId)]); 
        end
        
        %Calculate dt
        try     
            dt = imuData.timestamps(imuMeasId) - imuData.timestamps(imuMeasId - 1);
        catch
            dt = imuData.timestamps(imuMeasId +1) - imuData.timestamps(imuMeasId);
        end
        
        %Extract the measurements
        imuAccel = imuData.measAccel(:, imuMeasId);
        imuOmega = imuData.measOmega(:, imuMeasId);
        
        %=======GTSAM=========
        currentSummarizedMeasurement.integrateMeasurement(imuAccel, imuOmega, dt);
        %=====================
        
        
        %Keep track of gravity
        g_w = -1*rotmat_from_quat(imuData.measOrient(:,1))'*[0 0 9.81]';
        
        
        %Predict the next state
        [xPrev] = integrateIMU(xPrev, imuAccel, imuOmega, dt, noiseParams, g_w);
        R_wimu = rotmat_from_quat(xPrev.q);
        R_imuw = R_wimu';
        p_imuw_w = xPrev.p;
        

        
        
        
        %Keep track of the state
        T_wimu_estimated(:,:, end+1) = inv([R_imuw -R_imuw*p_imuw_w; 0 0 0 1]);

   
    % Camera Measurement 
    % ==========================================================
    elseif strcmp(measType, 'Cam')
        if pipelineOptions.verbose
            disp(['Processing Camera Measurement. ID: ' num2str(camMeasId)]); 
        end
        
        

        %Get measurement data
        %camMeasId
        currImage = monoImageData.rectImages(:,:,camMeasId);
                
   
        %The last IMU state based on integration (relative to the world)
        T_wimu_int = T_wimu_estimated(:,:, end);

  
             
       %If it's the first camera measurements, we're done. Otherwise
       %continue with pipeline
       largeInt = 10000;
        if firstImageProcessed == false
       
       firstImageProcessed = true;
        %Extract keyPoints
        keyPoints = detectFASTFeatures(mat2gray(currImage));
        keyPoints = keyPoints.selectStrongest(pipelineOptions.featureCount);
        keyPointPixels = keyPoints.Location(:,:)';
        keyPointIds = camMeasId*largeInt + [1:size(keyPointPixels,2)];
        
       %Save data into the referencePose struct
           referencePose.allKeyPointPixels = keyPointPixels;
           referencePose.T_wimu_int = T_wimu_int;
           referencePose.T_wimu_opt = T_wimu_int;
           referencePose.T_wcam_opt = T_wimu_int*inv(T_camimu);
           referencePose.allLandmarkIds = keyPointIds;
           referencePose.currImage = currImage;
          referencePose.camMeasId = camMeasId;

       
                   % =========== GTSAM ============
            % Initialization
            currentPoseKey = symbol('x',1);
            currentVelKey =  symbol('v',1);
            currentBiasKey = symbol('b',1);

            %Initialize the state
            newValues.insert(currentPoseKey, currentPoseGlobal);
             newValues.insert(currentVelKey, currentVelocityGlobal);
            newValues.insert(currentBiasKey, currentBias);
            
            %Add constraints
            %newFactors.add(PriorFactorPose3(currentPoseKey, currentPoseGlobal, sigma_init_x));
            newFactors.add(NonlinearEqualityPose3(currentPoseKey, currentPoseGlobal));
            newFactors.add(NonlinearEqualityLieVector(currentVelKey, currentVelocityGlobal));
             newFactors.add(NonlinearEqualityConstantBias(currentBiasKey, currentBias));
            
            %Prepare for IMU Integration
            currentSummarizedMeasurement = gtsam.ImuFactorPreintegratedMeasurements( ...
                      currentBias, diag(noiseParams.sigma_a.^2), ...
                      diag(noiseParams.sigma_g.^2), 1e-5 * eye(3));
                
            %Note: We cannot add landmark observations just yet because we
            %cannot be sure that all landmarks will be observed from the
            %next pose (if they are not, the system is underconstrained and  ill-posed)
           
            % ==============================

        else
              %The odometry change  
              T_rimu = inv(referencePose.T_wimu_int)*T_wimu_int;
              
              %Important: look at the composition!
              T_rcam = T_camimu*T_rimu*inv(T_camimu);
              R_rcam = T_rcam(1:3,1:3);
              p_camr_r = homo2cart(T_rcam*[0 0 0 1]');
              
            
            %Use KL-tracker to find locations of new points
            KLOldKeyPoints = num2cell(double(referencePose.allKeyPointPixels'), 2)';
            keyPointIds = referencePose.allLandmarkIds;

            [KLNewKeyPoints, status, ~] = cv.calcOpticalFlowPyrLK(uint8(referencePose.currImage), uint8(currImage), KLOldKeyPoints);
            
            
            KLOldkeyPointPixels = cell2mat(KLOldKeyPoints(:))';
            KLNewkeyPointPixels = cell2mat(KLNewKeyPoints(:))';
           
            % Remove any points that have negative coordinates
            negCoordIdx = KLNewkeyPointPixels(1,:) < 0 | KLNewkeyPointPixels(2,:) < 0;
            badIdx = negCoordIdx | (status == 0)';
            KLNewkeyPointPixels(:, badIdx) = [];
            KLOldkeyPointPixels(:, badIdx) = [];
            keyPointIds(badIdx) = [];
         
             %Recalculate the unit vectors
            KLOldkeyPointUnitVectors = normalize(invK*cart2homo(KLOldkeyPointPixels));
            KLNewkeyPointUnitVectors = normalize(invK*cart2homo(KLNewkeyPointPixels));
            
           
           %Unit bearing vectors for all matched points
           matchedReferenceUnitVectors = KLOldkeyPointUnitVectors;
           matchedCurrentUnitVectors =  KLNewkeyPointUnitVectors;
           
           
           %=======DO WE NEED A NEW KEYFRAME?=============
           %Calculate disparity between the current frame the last keyFramePose
           %disparityMeasure = calcDisparity(matchedReferenceUnitVectors, matchedCurrentUnitVectors, R_rcam, K);
          disparityMeasure = calcDisparity(KLOldkeyPointPixels, KLNewkeyPointPixels);
          disp(['Disparity Measure: ' num2str(disparityMeasure)]);
           
           
          if (~initiliazationComplete && disparityMeasure > pipelineOptions.initDisparityThreshold)  || (initiliazationComplete && disparityMeasure > pipelineOptions.kfDisparityThreshold) %(~initiliazationComplete && norm(p_camr_r) > 1) || (initiliazationComplete && norm(p_camr_r) > 1) %(disparityMeasure > INIT_DISPARITY_THRESHOLD) 

              
                   disp(['Creating new keyframe: ' num2str(keyFrame_i)]);   

                     %=========== GTSAM ===========
        
        % At each non=IMU measurement we initialize a new node in the graph
          currentPoseKey = symbol('x',keyFrame_i+1);
          currentVelKey =  symbol('v',keyFrame_i+1);
          currentBiasKey = symbol('b',keyFrame_i+1);
  
             %Important, we keep track of the optimized state and 'compose'
      %odometry onto it!
      currPose = Pose3(referencePose.T_wimu_opt*T_rimu);
      %newFactors.add(PriorFactorPose3(currentPoseKey, Pose3(T_wimu_int),noiseModel.Isotropic.Sigma(6,1)));

      
   
             % Summarize IMU data between the previous GPS measurement and now
               newFactors.add(ImuFactor( ...
       currentPoseKey-1, currentVelKey-1, ...
       currentPoseKey, currentVelKey, ...
      currentBiasKey, currentSummarizedMeasurement, g_w, w_coriolis));

        %Prepare for IMU Integration
            currentSummarizedMeasurement = gtsam.ImuFactorPreintegratedMeasurements( ...
                      currentBias, diag(noiseParams.sigma_a.^2), ...
                      diag(noiseParams.sigma_g.^2), 1e-5 * eye(3));

        
       %Keep track of BIAS      
       newFactors.add(BetweenFactorConstantBias(currentBiasKey-1, currentBiasKey, imuBias.ConstantBias(zeros(3,1), zeros(3,1)), noiseModel.Diagonal.Sigmas(sigma_between_b)));

    newValues.insert(currentPoseKey, currPose);
     newValues.insert(currentVelKey, currentVelocityGlobal);
     newValues.insert(currentBiasKey, currentBias);
    
        %=============================
       
               %Feature descriptors 
               %matchedRelFeatures = referencePose.allkeyPointFeatures(matchedRelIndices(:,1), :);
                
              
              %[~, ~, inlierIdx1] = frame2frameRANSAC(matchedReferenceUnitVectors, matchedCurrentUnitVectors, R_rcam);
              inlierIdx2 = findInliers(matchedReferenceUnitVectors, matchedCurrentUnitVectors, R_rcam, p_camr_r, KLNewkeyPointPixels, K, pipelineOptions);
              
              %inlierIdx = intersect(inlierIdx1, inlierIdx2);
              inlierIdx = inlierIdx2;

              %matchedRelFeatures = matchedRelFeatures(inlierIdx, :); 
              matchedReferenceUnitVectors = matchedReferenceUnitVectors(:, inlierIdx);
              matchedCurrentUnitVectors = matchedCurrentUnitVectors(:, inlierIdx);
               
               %Triangulate features
               %All points are expressed in the reference frame
               triangPoints_r = triangulate(matchedReferenceUnitVectors, matchedCurrentUnitVectors, R_rcam, p_camr_r); 
               triangPoints_w = homo2cart(referencePose.T_wcam_opt*cart2homo(triangPoints_r));
    
               %Extract the raw pixel measurements
               matchedKeyPointsPixels = KLNewkeyPointPixels(:, inlierIdx);
               matchedRefKeyPointsPixels = KLOldkeyPointPixels(:, inlierIdx);
               matchedKeyPointIds = keyPointIds(inlierIdx);
               
                  %New STEP
              %Calculate the predicition vectors
              %=========================================
              matchedPredVectors = computePredVectors(matchedKeyPointsPixels, rgbImageData.rectImages(:,:,:, camMeasId), [imuAccel; imuOmega]);
              matchedRefPredVectors = computePredVectors(matchedRefKeyPointsPixels, rgbImageData.rectImages(:,:,:, referencePose.camMeasId), [imuAccel; imuOmega]);
             %=========================================

               
               printf(['--------- \n Matched ' num2str(length(inlierIdx)) ' old landmarks. ---------\n']);

               
               %Extract more FAST features to keep an constant number
               
               if pipelineOptions.featureCount - length(inlierIdx) > 0
                newkeyPoints = detectFASTFeatures(mat2gray(currImage));
                newkeyPoints = newkeyPoints.selectStrongest(pipelineOptions.featureCount - length(inlierIdx));
                newkeyPointPixels = newkeyPoints.Location(:,:)';
                newkeyPointIds = camMeasId*largeInt + [1:size(newkeyPointPixels,2)];
               else
                   newkeyPointPixels = [];
                   newkeyPointIds = [];
               end 
               
               %Show feature tracks if requested
               if keyFrame_i > 0 && pipelineOptions.showFeatureTracks
                    showMatchedFeatures(referencePose.currImage,currImage, matchedRefKeyPointsPixels', matchedKeyPointsPixels');
                    clusterIds = getClusterIds(matchedPredVectors, clusteringModel);
                    
                    colourRings = {'mo', 'co', 'ko'};
                    for c_n = 1:length(pipelineOptions.showClusterIdNums)
                        plot(matchedKeyPointsPixels(1, clusterIds == pipelineOptions.showClusterIdNums(c_n)), matchedKeyPointsPixels(2, clusterIds == pipelineOptions.showClusterIdNums(c_n)), colourRings{c_n} ,'MarkerSize',10);
                    end
                    drawnow;
                    pause(0.01);
               end
               
                             %=========GTSAM==========
                %Extract intrinsics
                f_x = K(1,1);
                f_y = K(2,2);
                c_x = K(1,3);
                c_y = K(2,3);

                % Create realistic calibration and measurement noise model
                % format: fx fy skew cx cy baseline
                K_GTSAM = Cal3_S2(f_x, f_y, 0, c_x, c_y);
                if pipelineOptions.useRobustMEst
                    mono_model_n_robust = noiseModel.Robust(noiseModel.mEstimator.Huber(pipelineOptions.mEstWeight), noiseModel.Isotropic.Sigma(2, pipelineOptions.obsNoiseSigma));
                else
                    mono_model_n_robust = noiseModel.Isotropic.Sigma(2, pipelineOptions.obsNoiseSigma);
                end
                  pointNoise = noiseModel.Isotropic.Sigma(3, pipelineOptions.triangPointSigma); 

                %approxBaseline = norm(p_camr_r);
                %Insert estimate for landmark, calculate
                %uncertainty
%                  pointNoiseMat = calcLandmarkUncertainty(matchedRefKeyPointsPixels(:,kpt_j), matchedKeyPointsPixels(:,kpt_j), eye(4), approxBaseline, K);
%                  pointNoise = noiseModel.Gaussian.Covariance(pointNoiseMat);
                                            
                    
                 
                
                %====== INITIALIZATION ========
               if ~initiliazationComplete
                      %Add a factor that constrains this pose (necessary for
                    %the the first 2 poses)
                    %newFactors.add(PriorFactorPose3(currentPoseKey, currPose, sigma_init_x));
                    if keyFrame_i == 1
                    newFactors.add(NonlinearEqualityPose3(currentPoseKey, currPose));
                    end
                    %Add observations of all matched landmarks
                    for kpt_j = 1:length(matchedKeyPointIds)
                         if ~newValues.exists(matchedKeyPointIds(kpt_j))
                             insertedLandmarkIds = [insertedLandmarkIds matchedKeyPointIds(kpt_j)];
                            initializedLandmarkIds = [initializedLandmarkIds matchedKeyPointIds(kpt_j)];

                            newValues.insert(matchedKeyPointIds(kpt_j), Point3(triangPoints_w(:, kpt_j)));
                            newFactors.add(GenericProjectionFactorCal3_S2(Point2((matchedRefKeyPointsPixels(:,kpt_j))), mono_model_n_robust, currentPoseKey-1, matchedKeyPointIds(kpt_j), K_GTSAM,  Pose3(inv(T_camimu))));
                           %newFactors.add(PriorFactorPoint3(matchedKeyPointIds(kpt_j), Point3(triangPoints_w(:, kpt_j)), pointNoise));
                         end
                         newFactors.add(GenericProjectionFactorCal3_S2(Point2((matchedKeyPointsPixels(:,kpt_j))), mono_model_n_robust, currentPoseKey, matchedKeyPointIds(kpt_j), K_GTSAM, Pose3(inv(T_camimu))));
                    end
                    if keyFrame_i == 1
                        initiliazationComplete = true;
                              %Batch optimize
                        batchOptimizer = LevenbergMarquardtOptimizer(newFactors, newValues);
                        fullyOptimizedValues = batchOptimizer.optimize();
                        isam.update(newFactors, fullyOptimizedValues);
                        isamCurrentEstimate = isam.calculateEstimate();
                        
                        %Reset the new values
                        newFactors = NonlinearFactorGraph;
                         newValues = Values;
                    end
               else
               %====== END INITIALIZATION ========
               
               %====== NORMAL ISAM OPERATION =====
               
               %Alright, here we go, we're going to keep track of landmarks
               %and insert them into the filter only when they go out of
               %view. This is very similar to what Mourikis does in his
               %MSCKF
               
               %Compare current observations to the list of all past
               %observations. The set difference are all the observations
               %we need to add. The trick is to keep track of all of the 
               %pose keys as well.
               
               
                             
                   %Keep track of all observed landmarks
                    for kpt_j = 1:length(matchedKeyPointIds)
                        % If this is the first time, we need to add the
                        % previous keyframe observation as well.
                         if ~ismember(matchedKeyPointIds(kpt_j), insertedLandmarkIds) 
                              insertedLandmarkIds = [insertedLandmarkIds matchedKeyPointIds(kpt_j)];

                              pastObservations.pixels = [pastObservations.pixels matchedRefKeyPointsPixels(:, kpt_j)];
                              pastObservations.poseKeys = [pastObservations.poseKeys (currentPoseKey-1)];
                              pastObservations.triangPoints = [pastObservations.triangPoints triangPoints_w(:,kpt_j)];
                              pastObservations.ids =  [pastObservations.ids matchedKeyPointIds(kpt_j)];
                              pastObservations.predVectors =  [pastObservations.predVectors matchedRefPredVectors(:, kpt_j)];
                         end
                         if ~ismember(matchedKeyPointIds(kpt_j), initializedLandmarkIds)
                              pastObservations.pixels = [pastObservations.pixels matchedKeyPointsPixels(:, kpt_j)];
                              pastObservations.poseKeys = [pastObservations.poseKeys (currentPoseKey)];
                              pastObservations.triangPoints = [pastObservations.triangPoints triangPoints_w(:,kpt_j)];
                              pastObservations.ids =  [pastObservations.ids matchedKeyPointIds(kpt_j)];
                              pastObservations.predVectors =  [pastObservations.predVectors matchedPredVectors(:, kpt_j)];
                         end
                    end
                    
                    obsGoneOutofViewIds = setdiff(pastObservations.ids, matchedKeyPointIds);
                         printf('%d landmarks gone out of view. Inserting into filter.', length(obsGoneOutofViewIds));
                    
                    %Add all landmarks that have gone out of view
                    for id = 1:length(obsGoneOutofViewIds)
                            kptId = obsGoneOutofViewIds(id);
                            allKptTriang = pastObservations.triangPoints(:, pastObservations.ids==kptId);
                            allKptObsPixels = pastObservations.pixels(:, pastObservations.ids==kptId);
                            allPoseKeys = pastObservations.poseKeys(:, pastObservations.ids==kptId);
                            allPredVectors = pastObservations.predVectors(:, pastObservations.ids==kptId);
                            
                            %Triangulate the point by taking the mean of
                            %all observations (starting from the 2nd one
                            %since we can't triangulate right away)
                            
                            kptLocEst = [mean(allKptTriang(1,2:end)); mean(allKptTriang(2,2:end)); mean(allKptTriang(3,2:end)) ];
                            %kptLocEst = allKptTriang(:,1);
                            tempValues = Values;
                            tempFactors = NonlinearFactorGraph;
                            
                            tempValues.insert(kptId, Point3(kptLocEst));
                             for obs_i = 1:size(allKptObsPixels,2)
                                 %THE MAGIC!
                                 %====================
                                 predVector = allPredVectors(:, obs_i);
                                 predWeight = getPredVectorWeight(predVector, clusteringModel, clusterWeights, pipelineOptions);
                                 mono_model_n_predictive = noiseModel.Robust(noiseModel.mEstimator.Huber(predWeight), noiseModel.Isotropic.Sigma(2, pipelineOptions.obsNoiseSigma));

                                tempFactors.add(GenericProjectionFactorCal3_S2(Point2(allKptObsPixels(:, obs_i)), mono_model_n_predictive, allPoseKeys(obs_i), kptId, K_GTSAM,  Pose3(inv(T_camimu))));
                                 %====================
                             end
                             uniquePoseKeys = unique(allPoseKeys);
                             
                             for pose_i = 1:length(uniquePoseKeys)
                                 tempValues.insert(uniquePoseKeys(pose_i), isamCurrentEstimate.at(uniquePoseKeys(pose_i)));
                                 tempFactors.add(NonlinearEqualityPose3(uniquePoseKeys(pose_i), isamCurrentEstimate.at(uniquePoseKeys(pose_i))));
                             end
                            
                               batchOptimizer = LevenbergMarquardtOptimizer(tempFactors, tempValues);
                               fullyOptimizedValues = batchOptimizer.optimize();
                        
                               kptLoc = fullyOptimizedValues.at(kptId).vector;
                              
                               if length(allPoseKeys) >= pipelineOptions.minViewingsForLandmark
                                if ~isamCurrentEstimate.exists(kptId)
                                    newValues.insert(kptId, Point3(kptLoc));
                                end

                                for obs_i = 1:size(allKptObsPixels,2)
                                 %THE MAGIC!
                                 %====================
                                 predVector = allPredVectors(:, obs_i);
                                 predWeight = getPredVectorWeight(predVector, clusteringModel, clusterWeights, pipelineOptions);
                                 mono_model_n_predictive = noiseModel.Robust(noiseModel.mEstimator.Huber(predWeight), noiseModel.Isotropic.Sigma(2, pipelineOptions.obsNoiseSigma));

                                    newFactors.add(GenericProjectionFactorCal3_S2(Point2(allKptObsPixels(:, obs_i)), mono_model_n_predictive, allPoseKeys(obs_i), kptId, K_GTSAM,  Pose3(inv(T_camimu))));
                                %====================
                                end
                                newFactors.add(PriorFactorPoint3(kptId, Point3(kptLoc), pointNoise));
                             end

       

                    end
                     
                    %Remove all added landmarks from qeueu
                    pastObservations.pixels(:,  ismember(pastObservations.ids, obsGoneOutofViewIds)) = [];
                    pastObservations.poseKeys(ismember(pastObservations.ids, obsGoneOutofViewIds)) = [];
                    pastObservations.triangPoints(:,  ismember(pastObservations.ids, obsGoneOutofViewIds)) = [];
                    pastObservations.predVectors(:,ismember(pastObservations.ids, obsGoneOutofViewIds)) = [];
                    pastObservations.ids(ismember(pastObservations.ids, obsGoneOutofViewIds)) = [];
                    
                    %Do the hard work ISAM!
                    isam.update(newFactors, newValues);
                    isamCurrentEstimate = isam.calculateEstimate();

                        
                    
                   %Reset the new values
                   newFactors = NonlinearFactorGraph;
                   newValues = Values;
             
               %==================================
               end %if initializationComplete

               
               %What is our current estimate of the state?
                currentVelocityGlobal = isamCurrentEstimate.at(currentVelKey);
                currentBias = isamCurrentEstimate.at(currentBiasKey);
                currentPoseGlobal = isamCurrentEstimate.at(currentPoseKey);

               
         
                %Plot the results
                
                
                if keyFrame_i ==1 
                    trajFig = figure;
                    trajAxes = axes();
                    set (trajFig, 'outerposition', [25 1000, 560, 470])
                end
                p_wimu_w = currentPoseGlobal.translation.vector;
                p_wimu_w_int = T_wimu_int(1:3,4);
                 plot(trajAxes, p_wimu_w(1), p_wimu_w(2), 'g*');
                 
                plot(trajAxes, p_wimu_w_int(1), p_wimu_w_int(2), 'r*');
                hold on;

                drawnow;
                pause(0.01);

               disp(['Triangulated landmarks: ' num2str(size(triangPoints_w,2))])
               

               %Save keyframe
            %Each keyframe requires:
               % 1. Absolute rotation and translation information (i.e. pose)
               % 2. Triangulated 3D points and associated descriptor vectors

               keyFrames(keyFrame_i).imuMeasId = size(T_wimu_estimated, 3);
              keyFrames(keyFrame_i).camMeasId = camMeasId;
               keyFrames(keyFrame_i).T_wimu_opt = currentPoseGlobal.matrix;
               keyFrames(keyFrame_i).T_wimu_int = T_wimu_int;
               keyFrames(keyFrame_i).T_wcam_opt = currentPoseGlobal.matrix*inv(T_camimu);
               keyFrames(keyFrame_i).pointCloud = triangPoints_w;
               keyFrames(keyFrame_i).landmarkIds = matchedKeyPointIds; %Unique integer associated with a landmark
               keyFrames(keyFrame_i).allKeyPointPixels = [matchedKeyPointsPixels  newkeyPointPixels];
               keyFrames(keyFrame_i).allLandmarkIds = [matchedKeyPointIds newkeyPointIds];
               keyFrames(keyFrame_i).currImage = currImage;

               %Update the reference pose
               referencePose = {};
               referencePose = keyFrames(keyFrame_i);

               keyFrame_i = keyFrame_i + 1;
                

                   
               
           end %if meanDisparity
           
           
        end % if camMeasId == 1
        
    end % strcmp(measType...)
    
    iter = iter + 1;
end % for measId = ...

%Output the final estimate
for kf_i = 1:(keyFrame_i-1)
    T_wimu_gtsam(:,:, kf_i) = isamCurrentEstimate.at(symbol('x', kf_i+1)).matrix;
end

end

